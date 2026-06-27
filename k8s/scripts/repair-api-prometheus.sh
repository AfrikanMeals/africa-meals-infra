#!/usr/bin/env bash
# Vérifie et répare le scrape Prometheus/Grafana pour africa-meals-api (k8s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=prometheus-host-gateway.sh
source "${SCRIPT_DIR}/prometheus-host-gateway.sh"
PROM_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

prom_query() {
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=${1}"
}

echo ""
echo "== 0/5 Prometheus host network =="
if ! prometheus_uses_host_network; then
  echo "Prometheus n'est PAS en network_mode=host — migration..." >&2
  "${SCRIPT_DIR}/recreate-prometheus-host.sh"
else
  echo "OK Prometheus network_mode=host"
fi

echo ""
echo "== 1/5 Sync cibles API =="
"${SCRIPT_DIR}/sync-prometheus-api-targets.sh"

echo ""
echo "== 2/5 kube-state-metrics =="
if [[ -x "${SCRIPT_DIR}/install-kube-state-metrics.sh" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh" || true
fi

echo ""
echo "== 3/5 Sonde depuis l'hôte =="
if curl -sf --max-time 5 "http://127.0.0.1:30900/api/metrics" 2>/dev/null | grep -q api_up; then
  echo "OK API NodePort : http://127.0.0.1:30900/api/metrics"
else
  echo "Échec API NodePort 30900 /api/metrics" >&2
fi

echo ""
echo "== 4/5 Requêtes Prometheus =="
sleep 2
if result="$(prom_query 'api_up' 2>/dev/null)" && echo "${result}" | grep -q '"value"'; then
  echo "OK api_up :"
  echo "${result}" | head -c 400
  echo ""
else
  echo "api_up vide — vérifier job africa-meals-api-pods" >&2
fi

if result="$(prom_query 'kube_deployment_status_replicas_available{deployment=\"africa-meals-api\",namespace=\"wise-eat\"}' 2>/dev/null)" \
  && echo "${result}" | grep -q '"value"'; then
  echo "OK kube_deployment_status_replicas_available (API)"
else
  echo "kube_deployment_status_replicas_available API vide" >&2
fi

echo ""
echo "Grafana : docker restart wise-eat-grafana"
echo "Dashboard : Servers → Africa Meals API (k8s)"
