#!/usr/bin/env bash
# Vérifie et répare le scrape Prometheus/Grafana pour africa-meals-ws (k8s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROM_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

prom_query() {
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=${1}"
}

echo "== 1/5 Sync cibles WS (relais socat ou NodePort) =="
"${SCRIPT_DIR}/sync-prometheus-ws-targets.sh"

echo ""
echo "== 2/5 kube-state-metrics =="
if [[ -x "${SCRIPT_DIR}/install-kube-state-metrics.sh" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh" || true
fi

echo ""
echo "== 3/5 Sonde depuis l'hôte =="
if curl -sf --max-time 5 "http://127.0.0.1:30080/metrics" | head -1 | grep -q .; then
  echo "OK kube-state-metrics : http://127.0.0.1:30080/metrics"
else
  echo "Échec kube-state-metrics NodePort 30080" >&2
fi

if curl -sf --max-time 5 "http://127.0.0.1:30800/api/metrics" | grep -q ws_up; then
  echo "OK WS NodePort : http://127.0.0.1:30800/api/metrics"
else
  echo "Échec WS NodePort 30800 /api/metrics" >&2
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  echo ""
  echo "== 4/5 Sonde depuis le conteneur Prometheus =="
  if docker exec wise-eat-prometheus wget -qO- --timeout=5 http://host.docker.internal:30080/metrics 2>/dev/null | head -1 | grep -q .; then
    echo "OK Prometheus → host.docker.internal:30080"
  else
    echo "Prometheus ne joint pas kube-state-metrics (host.docker.internal:30080)" >&2
  fi

  if docker exec wise-eat-prometheus wget -qO- --timeout=5 "http://host.docker.internal:${WS_NODEPORT:-30800}/api/metrics" 2>/dev/null | grep -q ws_up; then
    echo "OK Prometheus → host.docker.internal:${WS_NODEPORT:-30800}/api/metrics"
  else
    echo "Prometheus ne joint pas WS NodePort — vérifier extra_hosts host-gateway" >&2
  fi

  echo ""
  echo "Cibles actives (extrait) :"
  curl -sf "${PROM_URL}/api/v1/targets" 2>/dev/null \
    | grep -oE '"job":"africa-meals-ws[^"]*"|"health":"[^"]*"|"lastError":"[^"]*"' \
    | head -20 || echo "(API targets indisponible)"
fi

echo ""
echo "== 5/5 Requêtes Prometheus (attendre ~30s si scrape récent) =="
sleep 2

if result="$(prom_query 'ws_up' 2>/dev/null)" && echo "${result}" | grep -q '"value"'; then
  echo "OK ws_up :"
  echo "${result}" | head -c 400
  echo ""
else
  echo "ws_up vide — vérifier ${INFRA_ROOT}/monitoring/prometheus/prometheus.yml (job africa-meals-ws-pods)" >&2
  echo "  docker restart wise-eat-prometheus" >&2
fi

if result="$(prom_query 'kube_deployment_status_replicas_available{deployment="africa-meals-ws",namespace="wise-eat"}' 2>/dev/null)" \
  && echo "${result}" | grep -q '"value"'; then
  echo "OK kube_deployment_status_replicas_available :"
  echo "${result}" | head -c 400
  echo ""
else
  echo "kube_deployment_status_replicas_available vide (job kube-state-metrics ?)" >&2
fi

echo ""
echo "Requêtes manuelles (syntaxe correcte) :"
echo "  curl -sG '${PROM_URL}/api/v1/query' --data-urlencode 'query=ws_up'"
echo "  curl -sG '${PROM_URL}/api/v1/query' --data-urlencode 'query=kube_deployment_status_replicas_available{deployment=\"africa-meals-ws\",namespace=\"wise-eat\"}'"
echo ""
echo "Grafana : docker restart wise-eat-grafana"
