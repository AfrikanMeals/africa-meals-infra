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
echo "== 0/6 node_exporter (Grafana Core System) =="
if [[ -x "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" ]]; then
  "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" || true
fi

echo ""
echo "== 1/6 Prometheus host network =="
if ! prometheus_uses_host_network; then
  echo "Prometheus n'est PAS en network_mode=host — migration..." >&2
  "${SCRIPT_DIR}/recreate-prometheus-host.sh"
else
  echo "OK Prometheus network_mode=host"
fi

echo ""
echo "== 1/6 Sync cibles API =="
"${SCRIPT_DIR}/sync-prometheus-api-targets.sh"

echo ""
echo "== 2/6 kube-state-metrics =="
if [[ -x "${SCRIPT_DIR}/install-kube-state-metrics.sh" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh" || true
fi

echo ""
echo "== 3/6 Sonde depuis l'hôte =="
if curl -sf --max-time 5 "http://127.0.0.1:30900/api/metrics" 2>/dev/null | grep -q api_up; then
  echo "OK API NodePort : http://127.0.0.1:30900/api/metrics"
else
  echo "Échec API NodePort 30900 /api/metrics (pods API down ?)" >&2
fi

echo ""
echo "== 4/6 Grafana → Prometheus =="
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-grafana'; then
  grafana_net="$(docker inspect wise-eat-grafana -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${grafana_net}" != "host" ]]; then
    echo "Grafana pas en host network — recréation..." >&2
    "${SCRIPT_DIR}/recreate-grafana-host.sh"
  elif docker exec wise-eat-grafana wget -qO- --timeout=5 'http://127.0.0.1:9090/-/ready' 2>/dev/null | grep -qi prometheus; then
    echo "OK Grafana joint Prometheus via 127.0.0.1:9090"
  else
    echo "Échec Grafana → Prometheus" >&2
    "${SCRIPT_DIR}/recreate-grafana-host.sh" || true
  fi
else
  echo "Conteneur wise-eat-grafana absent — sudo ${SCRIPT_DIR}/recreate-grafana-host.sh" >&2
fi

echo ""
echo "== 5/6 Requêtes Prometheus =="
sleep 2
if result="$(prom_query 'api_up' 2>/dev/null)" && echo "${result}" | grep -q '"value"'; then
  echo "OK api_up :"
  echo "${result}" | head -c 400
  echo ""
else
  echo "api_up vide — vérifier job africa-meals-api-pods / nodeport 30900" >&2
fi

if result="$(prom_query 'kube_deployment_status_replicas_available{deployment=\"africa-meals-api\",namespace=\"wise-eat\"}' 2>/dev/null)" \
  && echo "${result}" | grep -q '"value"'; then
  echo "OK kube_deployment_status_replicas_available (API)"
else
  echo "kube_deployment_status_replicas_available API vide (kube-state-metrics ?)" >&2
fi

echo ""
echo "== 6/6 Dashboard Grafana =="
dash="${INFRA_ROOT}/monitoring/grafana/dashboards/Servers/africa-meals-api-k8s.json"
if [[ -f "${dash}" ]]; then
  echo "OK dashboard provisionné : Servers / Africa Meals API (k8s)"
  echo "  docker restart wise-eat-grafana si absent dans l'UI"
else
  echo "Dashboard manquant : ${dash}" >&2
fi

echo ""
echo "Réparation complète : sudo ${SCRIPT_DIR}/repair-grafana-monitoring.sh"
