#!/usr/bin/env bash
# Met à jour les cibles Prometheus pour scraper /api/metrics de chaque pod WS.
#
# Prometheus tourne dans Docker : il ne peut PAS joindre les IP pods k3s (10.42.x.x).
# Mécanisme : relais socat sur l'hôte (0.0.0.0:2808x → podIP:8000), cibles host.docker.internal:2808x
# Secours sans socat : NodePort 30800 (métriques avec label pod= depuis l'app).
#
# Usage : sudo ./sync-prometheus-ws-targets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=prometheus-host-gateway.sh
source "${SCRIPT_DIR}/prometheus-host-gateway.sh"
TARGETS_DIR="${INFRA_ROOT}/monitoring/prometheus/targets"
TARGETS_FILE="${TARGETS_DIR}/ws-pods.json"
K8S_HOST_TARGETS="${TARGETS_DIR}/k8s-host.json"
NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
RELAY_BASE="${WS_METRICS_RELAY_BASE_PORT:-28080}"
PID_DIR="${WS_METRICS_RELAY_PID_DIR:-/var/run/ws-prometheus-relay}"
USE_RELAY="${WS_POD_METRICS_RELAY:-1}"
NODEPORT="${WS_NODEPORT:-30800}"
KSM_PORT="${KUBE_STATE_METRICS_NODEPORT:-30080}"

SCRAPE_HOST="$(prometheus_resolve_host_gateway)" || {
  echo "Impossible de résoudre l'IP hôte pour Prometheus (réseau wise-eat-infra ?)." >&2
  exit 1
}
prometheus_host_gateway_warn
echo "Passerelle scrape Prometheus : ${SCRAPE_HOST} (hôte VPS)"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

mkdir -p "${TARGETS_DIR}" "${PID_DIR}"

ws_stop_relays() {
  local f pid
  shopt -s nullglob
  for f in "${PID_DIR}"/*.pid; do
    pid="$(cat "${f}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
    rm -f "${f}"
  done
  shopt -u nullglob
  pkill -f "socat TCP-LISTEN:${RELAY_BASE}" 2>/dev/null || true
}

mapfile -t POD_LINES < <(
  "${KUBECTL[@]}" get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=africa-meals-ws \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}' \
    2>/dev/null | grep -E $'\t[0-9]+\.' || true
)

if [[ ${#POD_LINES[@]} -eq 0 ]]; then
  ws_stop_relays
  echo "[]" > "${TARGETS_FILE}"
  echo "Aucun pod WS Running — ${TARGETS_FILE} vidé." >&2
  exit 0
fi

write_targets_json() {
  local -a entries=("$@")
  {
    echo '['
    local i=0
    for entry in "${entries[@]}"; do
      [[ -n "${entry}" ]] || continue
      IFS=$'\t' read -r pod_name target_hostport <<< "${entry}"
      [[ ${i} -gt 0 ]] && echo ','
      echo '  {'
      echo "    \"targets\": [\"${target_hostport}\"],"
      echo '    "labels": {'
      echo '      "job": "africa-meals-ws-pods",'
      echo '      "service": "africa-meals-ws",'
      echo "      \"namespace\": \"${NAMESPACE}\","
      echo "      \"pod\": \"${pod_name}\""
      echo '    }'
      echo -n '  }'
      i=$((i + 1))
    done
    echo ''
    echo ']'
  } > "${TARGETS_FILE}"
}

ENTRIES=()
RELAY_OK=true

if [[ "${USE_RELAY}" == "1" ]] && command -v socat >/dev/null 2>&1; then
  ws_stop_relays
  idx=0
  for line in "${POD_LINES[@]}"; do
    IFS=$'\t' read -r pod_name pod_ip <<< "${line}"
    [[ -n "${pod_name}" && -n "${pod_ip}" ]] || continue
    port=$((RELAY_BASE + idx))
    idx=$((idx + 1))
    socat "TCP-LISTEN:${port},fork,reuseaddr,bind=0.0.0.0" "TCP:${pod_ip}:8000" </dev/null >/dev/null 2>&1 &
    relay_pid=$!
    sleep 0.15
    if ! kill -0 "${relay_pid}" 2>/dev/null; then
      echo "Échec relais socat port ${port} → ${pod_ip}:8000" >&2
      RELAY_OK=false
      break
    fi
    if ! curl -sf --max-time 2 "http://127.0.0.1:${port}/api/health" >/dev/null; then
      echo "Relais port ${port} ne répond pas (/api/health)" >&2
      kill "${relay_pid}" 2>/dev/null || true
      RELAY_OK=false
      break
    fi
    echo "${relay_pid}" > "${PID_DIR}/${pod_name}.pid"
    ENTRIES+=("${pod_name}"$'\t'"${SCRAPE_HOST}:${port}")
  done
  if [[ "${RELAY_OK}" == "true" && ${#ENTRIES[@]} -gt 0 ]]; then
    write_targets_json "${ENTRIES[@]}"
    echo "Prometheus targets (relais socat) : ${#ENTRIES[@]} pod(s) → ports ${RELAY_BASE}-$((RELAY_BASE + idx - 1))"
  else
    ws_stop_relays
    RELAY_OK=false
  fi
else
  RELAY_OK=false
fi

if [[ "${RELAY_OK}" == "false" ]]; then
  if [[ "${USE_RELAY}" == "1" ]] && ! command -v socat >/dev/null 2>&1; then
    echo "socat absent — secours NodePort :${NODEPORT} (apt install -y socat)." >&2
  fi
  write_targets_json "nodeport-aggregate"$'\t'"${SCRAPE_HOST}:${NODEPORT}"
  echo "Prometheus targets (NodePort) : ${SCRAPE_HOST}:${NODEPORT}"
fi

echo "Fichier : ${TARGETS_FILE}"
cat "${TARGETS_FILE}"

{
  echo '['
  echo '  {'
  echo "    \"targets\": [\"${SCRAPE_HOST}:${KSM_PORT}\"],"
  echo '    "labels": {'
  echo '      "namespace": "kube-system",'
  echo '      "service": "kube-state-metrics"'
  echo '    }'
  echo '  },'
  echo '  {'
  echo "    \"targets\": [\"${SCRAPE_HOST}:${NODEPORT}\"],"
  echo '    "labels": {'
  echo '      "service": "africa-meals-ws",'
  echo '      "scrape": "nodeport"'
  echo '    }'
  echo '  }'
  echo ']'
} > "${K8S_HOST_TARGETS}"
echo "Passerelle k8s : ${K8S_HOST_TARGETS} (${SCRAPE_HOST}:${KSM_PORT}, :${NODEPORT})"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null; then
    echo "Prometheus rechargé (/-/reload)."
  else
    echo "Reload échoué — redémarrage conteneur..." >&2
    docker restart wise-eat-prometheus >/dev/null
    sleep 3
    echo "Prometheus redémarré."
  fi
fi
