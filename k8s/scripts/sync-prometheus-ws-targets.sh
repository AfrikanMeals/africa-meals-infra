#!/usr/bin/env bash
# Met à jour les cibles Prometheus pour scraper chaque pod WS (/api/metrics).
# Usage : ./sync-prometheus-ws-targets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGETS_DIR="${INFRA_ROOT}/monitoring/prometheus/targets"
TARGETS_FILE="${TARGETS_DIR}/ws-pods.json"
NAMESPACE="${K8S_NAMESPACE:-wise-eat}"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

mkdir -p "${TARGETS_DIR}"

mapfile -t IPS < <(
  "${KUBECTL[@]}" get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=africa-meals-ws \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}' \
    2>/dev/null | grep -E '^[0-9]+\.' || true
)

if [[ ${#IPS[@]} -eq 0 ]]; then
  echo "[]" > "${TARGETS_FILE}"
  echo "Aucun pod WS Running — ${TARGETS_FILE} vidé." >&2
  exit 0
fi

{
  echo '['
  echo '  {'
  echo -n '    "targets": ['
  first=true
  for ip in "${IPS[@]}"; do
    [[ -n "${ip}" ]] || continue
    if [[ "${first}" == true ]]; then
      first=false
    else
      echo -n ', '
    fi
    echo -n "\"${ip}:8000\""
  done
  echo '],'
  echo '    "labels": {'
  echo '      "job": "africa-meals-ws-pods",'
  echo '      "service": "africa-meals-ws",'
  echo '      "namespace": "'"${NAMESPACE}"'"'
  echo '    }'
  echo '  }'
  echo ']'
} > "${TARGETS_FILE}"

echo "Prometheus targets : ${#IPS[@]} pod(s) → ${TARGETS_FILE}"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null \
    && echo "Prometheus rechargé (/-/reload)." \
    || echo "Recharger Prometheus : docker restart wise-eat-prometheus" >&2
fi
