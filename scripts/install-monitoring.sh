#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component monitoring
cd "${MON_DIR}"
ensure_docker

if [[ ! -f .env.monitoring ]]; then
  cp .env.example .env.monitoring
  chmod 600 .env.monitoring
fi

if [[ -f "${REDIS_ENV}" ]]; then
  set -a && source "${REDIS_ENV}" && set +a
  sed -i "s|^CACHE_REDIS_PASSWORD=.*|CACHE_REDIS_PASSWORD=${CACHE_REDIS_PASSWORD}|" .env.monitoring
  sed -i "s|^BULL_REDIS_PASSWORD=.*|BULL_REDIS_PASSWORD=${BULL_REDIS_PASSWORD}|" .env.monitoring
fi

set -a && source .env.monitoring && set +a

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}|" .env.monitoring
  log "Mot de passe Grafana généré → ${MON_DIR}/.env.monitoring"
fi

if [[ -z "${PROMETHEUS_BASIC_AUTH_PASSWORD:-}" ]]; then
  PROMETHEUS_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  if grep -q '^PROMETHEUS_BASIC_AUTH_PASSWORD=' .env.monitoring; then
    sed -i "s|^PROMETHEUS_BASIC_AUTH_PASSWORD=.*|PROMETHEUS_BASIC_AUTH_PASSWORD=${PROMETHEUS_BASIC_AUTH_PASSWORD}|" .env.monitoring
  else
    echo "PROMETHEUS_BASIC_AUTH_PASSWORD=${PROMETHEUS_BASIC_AUTH_PASSWORD}" >> .env.monitoring
  fi
  log "Mot de passe Prometheus (nginx basic auth) généré → ${MON_DIR}/.env.monitoring"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh"

docker compose --env-file .env.monitoring pull
docker compose --env-file .env.monitoring up -d
sleep 5

docker compose --env-file .env.monitoring ps
echo ""

if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée"
else
  warn "Prometheus reload HTTP indisponible — redémarrage conteneur"
  docker compose --env-file .env.monitoring restart prometheus
  sleep 3
fi

bash "${SCRIPT_DIR}/verify-monitoring.sh" || true

echo ""
log "Métriques Redis : curl -s http://127.0.0.1:9121/metrics | grep '^redis_up '"
log "Métriques Memcached : curl -s http://127.0.0.1:9150/metrics | grep '^memcached_up '"
log "Grafana   : https://console.wise-eat.com (ou tunnel SSH → :3000)"
log "Prometheus: https://logs.wise-eat.com (basic auth — voir .env.monitoring)"
log "Dashboards : Redis · Memcached (job=All, instance=All)"
