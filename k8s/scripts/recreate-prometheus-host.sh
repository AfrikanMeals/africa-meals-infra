#!/usr/bin/env bash
# Recrée wise-eat-prometheus en network_mode=host (scrape k3s NodePort + pods sans passerelle Docker).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MONITORING_DIR="${INFRA_ROOT}/monitoring"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

if [[ ! -f "${MONITORING_DIR}/prometheus/prometheus.yml" ]]; then
  echo "Répertoire monitoring introuvable : ${MONITORING_DIR}" >&2
  exit 1
fi

RETENTION="${PROMETHEUS_RETENTION:-15d}"
EXTERNAL_URL="${PROMETHEUS_EXTERNAL_URL:-http://127.0.0.1:9090/}"

echo "Recréation wise-eat-prometheus (network_mode=host)..."
PROM_VOLUME="wise-eat-prometheus-data"
if docker inspect wise-eat-prometheus >/dev/null 2>&1; then
  existing_vol="$(docker inspect wise-eat-prometheus -f '{{range .Mounts}}{{if eq .Destination "/prometheus"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
  [[ -n "${existing_vol}" ]] && PROM_VOLUME="${existing_vol}"
fi

docker stop wise-eat-prometheus 2>/dev/null || true
docker rm wise-eat-prometheus 2>/dev/null || true

docker run -d \
  --name wise-eat-prometheus \
  --restart unless-stopped \
  --network host \
  --memory "${PROMETHEUS_MEM_LIMIT:-512m}" \
  --memory-swap "${PROMETHEUS_MEMSWAP_LIMIT:-768m}" \
  -v "${MONITORING_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "${MONITORING_DIR}/prometheus/alerts:/etc/prometheus/alerts:ro" \
  -v "${MONITORING_DIR}/prometheus/targets:/etc/prometheus/targets:ro" \
  -v "${PROM_VOLUME}:/prometheus" \
  prom/prometheus:v2.54.1 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time="${RETENTION}" \
  --web.enable-lifecycle \
  --web.listen-address=127.0.0.1:9090 \
  --web.external-url="${EXTERNAL_URL}"

sleep 2
if curl -sf http://127.0.0.1:9090/-/ready >/dev/null; then
  echo "OK — Prometheus host network sur http://127.0.0.1:9090"
else
  echo "Prometheus ne répond pas sur :9090" >&2
  docker logs wise-eat-prometheus --tail 30 >&2
  exit 1
fi

echo ""
echo "Mettre à jour les cibles WS :"
echo "  sudo ${SCRIPT_DIR}/sync-prometheus-ws-targets.sh"
