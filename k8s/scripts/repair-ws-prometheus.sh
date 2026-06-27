#!/usr/bin/env bash
# Vérifie et répare le scrape Prometheus/Grafana pour africa-meals-ws (k8s).
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
echo "== 0/5 Prometheus host network (recommandé VPS) =="
if ! prometheus_uses_host_network; then
  echo "Prometheus n'est PAS en network_mode=host — migration automatique..." >&2
  "${SCRIPT_DIR}/recreate-prometheus-host.sh"
else
  echo "OK Prometheus network_mode=host"
fi

echo ""
echo "== 1/5 Sync cibles WS =="
"${SCRIPT_DIR}/sync-prometheus-ws-targets.sh"

echo ""
echo "== 2/5 kube-state-metrics =="
if [[ -x "${SCRIPT_DIR}/install-kube-state-metrics.sh" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh" || true
fi

echo ""
echo "== 3/5 Sonde depuis l'hôte =="
if curl -sf --max-time 5 "http://127.0.0.1:30080/metrics" 2>/dev/null | grep -q kube_; then
  echo "OK kube-state-metrics : http://127.0.0.1:30080/metrics"
else
  echo "Échec kube-state-metrics :30080 — ss -tlnp | grep 30080" >&2
fi

if curl -sf --max-time 5 "http://127.0.0.1:30800/api/metrics" | grep -q ws_up; then
  echo "OK WS NodePort : http://127.0.0.1:30800/api/metrics"
else
  echo "Échec WS NodePort 30800 /api/metrics" >&2
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  SCRAPE_HOST="$(prometheus_resolve_host_gateway 2>/dev/null || echo '127.0.0.1')"
  echo ""
  echo "== 4/5 Sonde depuis le conteneur Prometheus (IP ${SCRAPE_HOST}) =="
  if docker exec wise-eat-prometheus wget -qO- --timeout=5 "http://${SCRAPE_HOST:-127.0.0.1}:30080/metrics" 2>/dev/null | head -1 | grep -q .; then
    echo "OK Prometheus → ${SCRAPE_HOST}:30080 (kube-state-metrics)"
  else
    echo "Prometheus ne joint pas kube-state-metrics (${SCRAPE_HOST}:30080)" >&2
  fi

  if docker exec wise-eat-prometheus wget -qO- --timeout=5 "http://${SCRAPE_HOST}:${WS_NODEPORT:-30800}/api/metrics" 2>/dev/null | grep -q ws_up; then
    echo "OK Prometheus → ${SCRAPE_HOST}:${WS_NODEPORT:-30800}/api/metrics"
  else
    echo "Prometheus ne joint pas WS (IP passerelle ${SCRAPE_HOST})" >&2
  fi

  echo ""
  echo "Cibles actives (extrait) :"
  curl -sf "${PROM_URL}/api/v1/targets" 2>/dev/null \
    | grep -oE '"job":"africa-meals-ws[^"]*"|"health":"[^"]*"|"lastError":"[^"]*"' \
    | head -20 || echo "(API targets indisponible)"
fi

echo ""
echo "== 4b/5 Grafana → Prometheus (127.0.0.1:9090) =="
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-grafana'; then
  grafana_net="$(docker inspect wise-eat-grafana -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${grafana_net}" != "host" ]]; then
    echo "Grafana n'est PAS en network_mode=host (host.docker.internal souvent absent sur Linux)." >&2
    if [[ -x "${SCRIPT_DIR}/recreate-grafana-host.sh" ]]; then
      "${SCRIPT_DIR}/recreate-grafana-host.sh"
    else
      echo "  sudo ${SCRIPT_DIR}/recreate-grafana-host.sh" >&2
    fi
  elif docker exec wise-eat-grafana wget -qO- --timeout=5 'http://127.0.0.1:9090/-/ready' 2>/dev/null | grep -qi prometheus; then
    echo "OK Grafana joint Prometheus via 127.0.0.1:9090"
  else
    echo "Échec Grafana → Prometheus — recréer Grafana + Prometheus host" >&2
    [[ -x "${SCRIPT_DIR}/recreate-grafana-host.sh" ]] && "${SCRIPT_DIR}/recreate-grafana-host.sh" || true
  fi
else
  echo "Conteneur wise-eat-grafana absent — sudo k8s/scripts/recreate-grafana-host.sh" >&2
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

if result="$(prom_query 'up{job="kube-state-metrics"}' 2>/dev/null)" && echo "${result}" | grep -q '"value":\[".*","1"\]'; then
  echo "OK up{job=kube-state-metrics}=1"
else
  echo "Échec scrape kube-state-metrics — curl http://127.0.0.1:30080/metrics | head" >&2
fi

if result="$(prom_query 'kube_deployment_status_replicas_available{deployment="africa-meals-ws",namespace="wise-eat"}' 2>/dev/null)" \
  && echo "${result}" | grep -q '"value"'; then
  echo "OK kube_deployment_status_replicas_available :"
  echo "${result}" | head -c 400
  echo ""
else
  echo "kube_deployment_status_replicas_available vide — fallback dashboard : count(ws_up==1)" >&2
  curl -s http://127.0.0.1:30080/metrics 2>/dev/null | grep -E 'kube_deployment.*africa-meals-ws' | head -3 || true
fi

echo ""
echo "Requêtes manuelles (syntaxe correcte) :"
echo "  curl -sG '${PROM_URL}/api/v1/query' --data-urlencode 'query=ws_up'"
echo "  curl -sG '${PROM_URL}/api/v1/query' --data-urlencode 'query=kube_deployment_status_replicas_available{deployment=\"africa-meals-ws\",namespace=\"wise-eat\"}'"
echo ""
echo "Grafana : docker restart wise-eat-grafana"
