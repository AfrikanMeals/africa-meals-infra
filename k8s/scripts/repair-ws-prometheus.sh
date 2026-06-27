#!/usr/bin/env bash
# Vérifie et répare le scrape Prometheus/Grafana pour africa-meals-ws (k8s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "== 1/4 Sync cibles WS (relais socat ou NodePort) =="
"${SCRIPT_DIR}/sync-prometheus-ws-targets.sh"

echo ""
echo "== 2/4 kube-state-metrics =="
if [[ -x "${SCRIPT_DIR}/install-kube-state-metrics.sh" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh" || true
fi

echo ""
echo "== 3/4 Sonde depuis l'hôte =="
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
  echo "== 4/4 Sonde depuis le conteneur Prometheus =="
  if docker exec wise-eat-prometheus wget -qO- --timeout=5 http://host.docker.internal:30080/metrics 2>/dev/null | head -1 | grep -q .; then
    echo "OK Prometheus → host.docker.internal:30080 (kube-state-metrics)"
  else
    echo "Prometheus ne joint pas kube-state-metrics via host.docker.internal:30080" >&2
    echo "  Vérifier extra_hosts host-gateway dans monitoring/docker-compose.yml" >&2
  fi

  if docker exec wise-eat-prometheus wget -qO- --timeout=5 "http://host.docker.internal:${WS_NODEPORT:-30800}/api/metrics" 2>/dev/null | grep -q ws_up; then
    echo "OK Prometheus → host.docker.internal:${WS_NODEPORT:-30800}/api/metrics"
  else
    echo "Prometheus ne joint pas WS NodePort" >&2
  fi

  echo ""
  echo "Requêtes Prometheus (attendre ~30s après reload) :"
  echo "  curl -s 'http://127.0.0.1:9090/api/v1/query?query=up{job=\"kube-state-metrics\"}'"
  echo "  curl -s 'http://127.0.0.1:9090/api/v1/query?query=ws_up'"
  echo "  curl -s 'http://127.0.0.1:9090/api/v1/query?query=kube_deployment_status_replicas_available{deployment=\"africa-meals-ws\"}'"
fi

echo ""
echo "Grafana : redémarrer si dashboard inchangé après git pull :"
echo "  docker restart wise-eat-grafana"
