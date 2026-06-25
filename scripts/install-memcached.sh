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

MEMCACHED_REPLICA_1_PORT="${MEMCACHED_REPLICA_1_PORT:-${MEMCACHED_B_PORT:-11213}}"
MEMCACHED_REPLICA_2_PORT="${MEMCACHED_REPLICA_2_PORT:-11214}"

COMPOSE_ARGS=(--env-file .env.memcached)
if memcached_cluster_b_enabled; then
  log "Memcached : 1 primary + 2 réplicas (:${MEMCACHED_REPLICA_1_PORT}, :${MEMCACHED_REPLICA_2_PORT})"
  COMPOSE_ARGS+=(--profile cluster-b)
  docker rm -f wise-eat-memcached-b 2>/dev/null || true
else
  log "Réplicas Memcached désactivés (MEMCACHED_CLUSTER_B_ENABLED=false)"
fi

log "Démarrage Memcached Docker"
docker compose "${COMPOSE_ARGS[@]}" pull
docker compose "${COMPOSE_ARGS[@]}" up -d
sleep 2
docker compose "${COMPOSE_ARGS[@]}" ps

if command -v nc >/dev/null 2>&1; then
  for spec in "${MEMCACHED_PORT:-11211}:primary" "${MEMCACHED_REPLICA_1_PORT}:replica-1" "${MEMCACHED_REPLICA_2_PORT}:replica-2"; do
    port="${spec%%:*}"
    name="${spec##*:}"
    if [[ "${name}" != "primary" ]] && ! memcached_cluster_b_enabled; then
      continue
    fi
    if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      log "OK  memcached ${name} :${port}"
    else
      warn "FAIL memcached ${name} :${port}"
    fi
  done
fi

cat <<EOF

Primary : 127.0.0.1:${MEMCACHED_PORT:-11211}
Réplicas (pools standby — bascule manuelle, pas sync auto) :
  127.0.0.1:${MEMCACHED_REPLICA_1_PORT}
  127.0.0.1:${MEMCACHED_REPLICA_2_PORT}

API : MEMCACHED_SERVERS=127.0.0.1:${MEMCACHED_PORT:-11211}
Failover : MEMCACHED_SERVERS=127.0.0.1:${MEMCACHED_REPLICA_1_PORT}

Memcached installé dans ${MEMCACHED_DIR}
EOF
