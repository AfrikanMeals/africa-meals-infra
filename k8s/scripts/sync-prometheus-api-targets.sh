#!/usr/bin/env bash
# Met à jour les cibles Prometheus pour scraper /api/metrics de chaque pod API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=prometheus-host-gateway.sh
source "${SCRIPT_DIR}/prometheus-host-gateway.sh"
TARGETS_DIR="${INFRA_ROOT}/monitoring/prometheus/targets"
TARGETS_FILE="${TARGETS_DIR}/api-pods.json"
K8S_HOST_TARGETS="${TARGETS_DIR}/k8s-host.json"
NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
RELAY_BASE="${API_METRICS_RELAY_BASE_PORT:-29090}"
PID_DIR="${API_METRICS_RELAY_PID_DIR:-/var/run/api-prometheus-relay}"
USE_RELAY="${API_POD_METRICS_RELAY:-1}"
NODEPORT="${API_NODEPORT:-30900}"
KSM_PORT="${KUBE_STATE_METRICS_NODEPORT:-30080}"

SCRAPE_HOST="$(prometheus_scrape_host)" || {
  echo "Impossible de résoudre l'adresse scrape." >&2
  exit 1
}
prometheus_host_gateway_warn
echo "Adresse scrape Prometheus : ${SCRAPE_HOST}"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

mkdir -p "${TARGETS_DIR}" "${PID_DIR}"

if [[ ! -s "${TARGETS_DIR}/api-pods.json" && -f "${TARGETS_DIR}/api-pods.json.example" ]]; then
  cp "${TARGETS_DIR}/api-pods.json.example" "${TARGETS_DIR}/api-pods.json"
fi

api_stop_relays() {
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
      echo '      "job": "africa-meals-api-pods",'
      echo '      "service": "africa-meals-api",'
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

prometheus_reload() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
    curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null \
      && echo "Prometheus rechargé (/-/reload)." \
      || docker restart wise-eat-prometheus >/dev/null
  fi
}

host_can_reach_api_metrics() {
  local pod_ip="$1"
  curl -sf --max-time 2 "http://${pod_ip}:9000/api/metrics" 2>/dev/null | grep -q api_up
}

mapfile -t POD_LINES < <(
  "${KUBECTL[@]}" get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=africa-meals-api \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}' \
    2>/dev/null | grep -E $'\t[0-9]+\.' || true
)

ENTRIES=()
TARGET_MODE=""

if [[ ${#POD_LINES[@]} -eq 0 ]]; then
  api_stop_relays
  write_targets_json "nodeport-aggregate"$'\t'"${SCRAPE_HOST}:${NODEPORT}"
  "${SCRIPT_DIR}/sync-prometheus-ws-targets.sh" >/dev/null 2>&1 || true
  echo "Aucun pod API Running — fallback NodePort ${SCRAPE_HOST}:${NODEPORT}" >&2
  cat "${TARGETS_FILE}"
  prometheus_reload
  exit 0
fi

if prometheus_uses_host_network; then
  for line in "${POD_LINES[@]}"; do
    IFS=$'\t' read -r pod_name pod_ip <<< "${line}"
    [[ -n "${pod_name}" && -n "${pod_ip}" ]] || continue
    if host_can_reach_api_metrics "${pod_ip}"; then
      ENTRIES+=("${pod_name}"$'\t'"${pod_ip}:9000")
    fi
  done
  if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    TARGET_MODE="direct-pod-ip"
    api_stop_relays
  fi
fi

if [[ ${#ENTRIES[@]} -eq 0 && "${USE_RELAY}" == "1" ]] && command -v socat >/dev/null 2>&1; then
  api_stop_relays
  bind_addr="0.0.0.0"
  prometheus_uses_host_network && bind_addr="127.0.0.1"
  idx=0
  RELAY_OK=true
  for line in "${POD_LINES[@]}"; do
    IFS=$'\t' read -r pod_name pod_ip <<< "${line}"
    [[ -n "${pod_name}" && -n "${pod_ip}" ]] || continue
    port=$((RELAY_BASE + idx))
    idx=$((idx + 1))
    socat "TCP-LISTEN:${port},fork,reuseaddr,bind=${bind_addr}" "TCP:${pod_ip}:9000" </dev/null >/dev/null 2>&1 &
    relay_pid=$!
    sleep 0.15
    if ! kill -0 "${relay_pid}" 2>/dev/null; then
      RELAY_OK=false
      break
    fi
    if ! curl -sf --max-time 2 "http://127.0.0.1:${port}/api/health" >/dev/null; then
      kill "${relay_pid}" 2>/dev/null || true
      RELAY_OK=false
      break
    fi
    echo "${relay_pid}" > "${PID_DIR}/${pod_name}.pid"
    ENTRIES+=("${pod_name}"$'\t'"${SCRAPE_HOST}:${port}")
  done
  if [[ "${RELAY_OK}" == "true" && ${#ENTRIES[@]} -gt 0 ]]; then
    TARGET_MODE="socat-relay"
  else
    api_stop_relays
    ENTRIES=()
  fi
fi

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  api_stop_relays
  write_targets_json "nodeport-aggregate"$'\t'"${SCRAPE_HOST}:${NODEPORT}"
  TARGET_MODE="nodeport-fallback"
  TARGET_COUNT=1
else
  write_targets_json "${ENTRIES[@]}"
  TARGET_COUNT="${#ENTRIES[@]}"
fi

"${SCRIPT_DIR}/sync-prometheus-ws-targets.sh" >/dev/null 2>&1 || true

echo "Mode cibles API : ${TARGET_MODE} (${TARGET_COUNT} entrée(s))"
echo "Fichier : ${TARGETS_FILE}"
cat "${TARGETS_FILE}"

prometheus_reload
