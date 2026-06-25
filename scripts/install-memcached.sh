#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component memcached
cd "${MEMCACHED_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.memcached ]]; then
  cp .env.example .env.memcached
  chmod 600 .env.memcached
  log "Fichier ${MEMCACHED_DIR}/.env.memcached créé (valeurs par défaut)"
fi

set -a && source .env.memcached && set +a

COMPOSE_ARGS=(--env-file .env.memcached)
if memcached_cluster_b_enabled; then
  log "Cluster B Memcached : port ${MEMCACHED_B_PORT:-11213}"
  COMPOSE_ARGS+=(--profile cluster-b)
else
  log "Cluster B Memcached désactivé (MEMCACHED_CLUSTER_B_ENABLED=false)"
fi

log "Démarrage Memcached Docker"
docker compose "${COMPOSE_ARGS[@]}" pull
docker compose "${COMPOSE_ARGS[@]}" up -d
sleep 2
docker compose "${COMPOSE_ARGS[@]}" ps

if command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "${MEMCACHED_PORT:-11211}" 2>/dev/null; then
    log "memcached (cluster A) : port ${MEMCACHED_PORT:-11211}"
  else
    warn "memcached cluster A : port ${MEMCACHED_PORT:-11211} inaccessible"
  fi
  if memcached_cluster_b_enabled; then
    if nc -z 127.0.0.1 "${MEMCACHED_B_PORT:-11213}" 2>/dev/null; then
      log "memcached-b (cluster B) : port ${MEMCACHED_B_PORT:-11213}"
    else
      warn "memcached-b : port ${MEMCACHED_B_PORT:-11213} inaccessible"
    fi
  fi
fi

cat <<EOF

API / africa-meals-api (.env) :
  # Cluster A seul
  MEMCACHED_SERVERS=127.0.0.1:${MEMCACHED_PORT:-11211}
  # Clusters A + B (sharding client — pas réplication)
  # MEMCACHED_SERVERS=127.0.0.1:${MEMCACHED_PORT:-11211},127.0.0.1:${MEMCACHED_B_PORT:-11213}

Memcached installé dans ${MEMCACHED_DIR}
EOF
