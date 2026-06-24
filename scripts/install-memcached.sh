#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component memcached
cd "${MEMCACHED_DIR}"
ensure_docker

if [[ ! -f .env.memcached ]]; then
  cp .env.example .env.memcached
  chmod 600 .env.memcached
  log "Fichier ${MEMCACHED_DIR}/.env.memcached créé (valeurs par défaut)"
fi

set -a && source .env.memcached && set +a

log "Démarrage Memcached Docker"
docker compose --env-file .env.memcached down 2>/dev/null || true
docker compose --env-file .env.memcached pull
docker compose --env-file .env.memcached up -d
sleep 2
docker compose --env-file .env.memcached ps

if command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "${MEMCACHED_PORT:-11211}" 2>/dev/null; then
    log "memcached : port ${MEMCACHED_PORT:-11211} ouvert"
  else
    warn "memcached : port ${MEMCACHED_PORT:-11211} inaccessible — voir docker logs wise-eat-memcached"
  fi
else
  log "memcached démarré (installez netcat pour un test TCP automatique)"
fi

cat <<EOF

API / africa-meals-api (.env) :
  MEMCACHED_SERVERS=127.0.0.1:${MEMCACHED_PORT:-11211}

Memcached installé dans ${MEMCACHED_DIR}
EOF
