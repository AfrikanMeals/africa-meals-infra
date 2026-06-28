#!/usr/bin/env bash
# Répare Grafana + Prometheus (node_exporter, k8s WS/API, dossier Servers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROM_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

prom_query() {
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=${1}" 2>/dev/null || true
}

echo "== 1/6 Cibles EMQX Docker (réplicas) =="
if [[ -x "${INFRA_ROOT}/scripts/sync-emqx-prometheus-targets.sh" ]]; then
  "${INFRA_ROOT}/scripts/sync-emqx-prometheus-targets.sh" || true
fi

echo ""
echo "== 2/6 Cibles Prometheus host (node_exporter :9100) =="
if [[ -x "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" ]]; then
  "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" || true
else
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
    if curl -sf -X POST "${PROM_URL}/-/reload" >/dev/null; then
      echo "OK Prometheus rechargé"
    else
      docker restart wise-eat-prometheus
      sleep 3
    fi
  fi
fi

echo ""
echo "== 3/6 node_exporter + Grafana host network =="
if ! prom_query 'up{job="node",instance="wise-eat:9100"}' | grep -q '"value":\[".*","1"\]'; then
  echo "node_exporter DOWN — sudo ${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" >&2
  curl -sf http://127.0.0.1:9100/metrics | head -1 || echo "  :9100 injoignable" >&2
else
  echo "OK up{job=node}=1"
fi

grafana_net="$(docker inspect wise-eat-grafana -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
if [[ "${grafana_net}" != "host" ]]; then
  echo "Grafana pas en host network — recréation..."
  "${SCRIPT_DIR}/recreate-grafana-host.sh"
else
  echo "OK Grafana network_mode=host"
fi

echo ""
echo "== 4/6 Dashboards Servers (WS + API k8s) =="
for dash in \
  "${INFRA_ROOT}/monitoring/grafana/dashboards/Servers/africa-meals-ws-k8s.json" \
  "${INFRA_ROOT}/monitoring/grafana/dashboards/Servers/africa-meals-api-k8s.json"; do
  if [[ -f "${dash}" ]]; then
    echo "  OK $(basename "${dash}")"
  else
    echo "  MANQUANT ${dash}" >&2
  fi
done

echo ""
echo "== 5/6 Scrape k8s WS + API =="
"${SCRIPT_DIR}/repair-ws-prometheus.sh" || true
"${SCRIPT_DIR}/repair-api-prometheus.sh" || true

echo ""
echo "== 6/6 Restart Grafana (recharge provisioning dashboards) =="
docker restart wise-eat-grafana >/dev/null
sleep 4
if curl -sf http://127.0.0.1:3000/api/health >/dev/null; then
  echo "OK Grafana http://127.0.0.1:3000"
else
  echo "Grafana ne répond pas" >&2
fi

echo ""
echo "Console : https://console.wise-eat.com"
echo "  Core System → Wise Eat — System (Node Exporter)"
echo "  Servers     → Africa Meals WS (k8s)"
echo "  Servers     → Africa Meals API (k8s)"
echo ""
echo "Vérification : sudo ${INFRA_ROOT}/scripts/verify-monitoring.sh"
