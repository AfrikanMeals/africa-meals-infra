#!/usr/bin/env bash
# Recrée wise-eat-grafana en network_mode=host (datasource Prometheus → 127.0.0.1:9090).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MONITORING_DIR="${INFRA_ROOT}/monitoring"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

if [[ ! -f "${MONITORING_DIR}/.env.monitoring" ]]; then
  echo "Fichier ${MONITORING_DIR}/.env.monitoring introuvable" >&2
  exit 1
fi

set -a && source "${MONITORING_DIR}/.env.monitoring" && set +a

GRAFANA_VOLUME="wise-eat-grafana-data"
if docker inspect wise-eat-grafana >/dev/null 2>&1; then
  existing_vol="$(docker inspect wise-eat-grafana -f '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
  [[ -n "${existing_vol}" ]] && GRAFANA_VOLUME="${existing_vol}"
fi

docker stop wise-eat-grafana 2>/dev/null || true
docker rm wise-eat-grafana 2>/dev/null || true

docker run -d \
  --name wise-eat-grafana \
  --restart unless-stopped \
  --network host \
  --memory "${GRAFANA_MEM_LIMIT:-256m}" \
  --memory-swap "${GRAFANA_MEMSWAP_LIMIT:-384m}" \
  -e GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}" \
  -e GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD requis dans .env.monitoring}" \
  -e GF_USERS_ALLOW_SIGN_UP=false \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 \
  -e GF_SERVER_HTTP_PORT=3000 \
  -e GF_SERVER_ROOT_URL="${GRAFANA_ROOT_URL:-http://127.0.0.1:3000/}" \
  -e GF_AUTH_ANONYMOUS_ENABLED=false \
  -e GF_SMTP_ENABLED="${GRAFANA_SMTP_ENABLED:-true}" \
  -e GF_SMTP_HOST="${GRAFANA_SMTP_HOST:-smtp.zoho.com:587}" \
  -e GF_SMTP_USER="${GRAFANA_SMTP_USER:-admin@wise-eat.com}" \
  -e GF_SMTP_PASSWORD="${GRAFANA_SMTP_PASSWORD:-}" \
  -e GF_SMTP_FROM_ADDRESS="${GRAFANA_SMTP_FROM_ADDRESS:-admin@wise-eat.com}" \
  -e GF_SMTP_FROM_NAME="${GRAFANA_SMTP_FROM_NAME:-Wise Eat Alerts}" \
  -e GF_SMTP_SKIP_VERIFY="${GRAFANA_SMTP_SKIP_VERIFY:-false}" \
  -v "${MONITORING_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "${MONITORING_DIR}/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  -v "${GRAFANA_VOLUME}:/var/lib/grafana" \
  grafana/grafana:13.1.0

sleep 3
if curl -sf http://127.0.0.1:3000/api/health >/dev/null; then
  echo "OK — Grafana host network sur http://127.0.0.1:3000"
else
  echo "Grafana ne répond pas sur :3000" >&2
  docker logs wise-eat-grafana --tail 30 >&2
  exit 1
fi

if docker exec wise-eat-grafana wget -qO- --timeout=5 http://127.0.0.1:9090/-/ready 2>/dev/null | grep -qi prometheus; then
  echo "OK — Grafana joint Prometheus (127.0.0.1:9090)"
else
  echo "Grafana ne joint pas Prometheus — sudo k8s/scripts/recreate-prometheus-host.sh" >&2
  exit 1
fi
