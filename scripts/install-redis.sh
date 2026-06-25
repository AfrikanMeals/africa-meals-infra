#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component redis
cd "${REDIS_DIR}"
ensure_docker
ensure_wise_eat_infra_network
stop_valkey_if_present

if [[ ! -f .env.redis ]]; then
  log "Création .env.redis (mots de passe aléatoires)"
  CACHE_REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  BULL_REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  cat > .env.redis <<EOF
CACHE_REDIS_PASSWORD=${CACHE_REDIS_PASSWORD}
BULL_REDIS_PASSWORD=${BULL_REDIS_PASSWORD}
EOF
  chmod 600 .env.redis
  log "Mots de passe enregistrés dans ${REDIS_DIR}/.env.redis"
fi

set -a && source .env.redis && set +a

regenerate_acl() {
  local file="$1" user="$2" pass="$3"
  cat > "${file}" <<EOF
user default off
user ${user} on >${pass} ~* &* +@all -flushall -flushdb -debug -config
EOF
}

log "Synchronisation ACL avec .env.redis"
regenerate_acl cache-users.acl wise-eat-cache "${CACHE_REDIS_PASSWORD}"
regenerate_acl bull-users.acl wise-eat-bull "${BULL_REDIS_PASSWORD}"

if [[ ! -f cache-users.acl ]] || [[ ! -f bull-users.acl ]]; then
  log "Fichiers ACL créés"
fi

mkdir -p data-cache data-bullmq
chown -R 999:999 data-cache data-bullmq
chown 999:999 cache-users.acl bull-users.acl
chmod 600 cache-users.acl bull-users.acl

log "Démarrage Redis Docker"
docker compose down 2>/dev/null || true
docker compose up -d
sleep 3
docker compose ps

if docker exec wise-eat-redis-cache redis-cli --user wise-eat-cache --pass "${CACHE_REDIS_PASSWORD}" ping | grep -q PONG; then
  log "redis-cache : PONG"
else
  warn "redis-cache ping échoué — voir docker logs wise-eat-redis-cache"
fi
if docker exec wise-eat-redis-bullmq redis-cli --user wise-eat-bull --pass "${BULL_REDIS_PASSWORD}" ping | grep -q PONG; then
  log "redis-bullmq : PONG"
else
  warn "redis-bullmq ping échoué — voir docker logs wise-eat-redis-bullmq"
fi

log "Redis installé dans ${REDIS_DIR}"
