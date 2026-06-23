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
  if ! grep -q '^CACHE_REDIS_PASSWORD=.\+' .env.monitoring 2>/dev/null; then
    sed -i "s|^CACHE_REDIS_PASSWORD=.*|CACHE_REDIS_PASSWORD=${CACHE_REDIS_PASSWORD}|" .env.monitoring
  fi
  if ! grep -q '^BULL_REDIS_PASSWORD=.\+' .env.monitoring 2>/dev/null; then
    sed -i "s|^BULL_REDIS_PASSWORD=.*|BULL_REDIS_PASSWORD=${BULL_REDIS_PASSWORD}|" .env.monitoring
  fi
fi

set -a && source .env.monitoring && set +a

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}|" .env.monitoring
  log "Mot de passe Grafana généré → ${MON_DIR}/.env.monitoring"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh"

docker compose --env-file .env.monitoring pull
docker compose --env-file .env.monitoring up -d
sleep 5

docker compose --env-file .env.monitoring ps
echo ""
log "Métriques : curl -s http://127.0.0.1:9121/metrics | grep '^redis_up '"
log "Grafana   : ssh -L 3000:127.0.0.1:3000 root@wise-eat.cloud → http://127.0.0.1:3000"
