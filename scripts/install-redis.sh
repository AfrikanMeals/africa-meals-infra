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
REDIS_CLUSTER_B_ENABLED=true
CACHE_REDIS_REPLICA_1_PORT=6371
CACHE_REDIS_REPLICA_2_PORT=6372
BULL_REDIS_REPLICA_1_PORT=6390
BULL_REDIS_REPLICA_2_PORT=6391
EOF
  chmod 600 .env.redis
  log "Mots de passe enregistrés dans ${REDIS_DIR}/.env.redis"
fi

set -a && source .env.redis && set +a

CACHE_REDIS_REPLICA_1_PORT="${CACHE_REDIS_REPLICA_1_PORT:-${CACHE_REDIS_REPLICA_PORT:-6371}}"
CACHE_REDIS_REPLICA_2_PORT="${CACHE_REDIS_REPLICA_2_PORT:-6372}"
BULL_REDIS_REPLICA_1_PORT="${BULL_REDIS_REPLICA_1_PORT:-${BULL_REDIS_REPLICA_PORT:-6390}}"
BULL_REDIS_REPLICA_2_PORT="${BULL_REDIS_REPLICA_2_PORT:-6391}"

regenerate_acl() {
  local file="$1" user="$2" pass="$3"
  cat > "${file}" <<EOF
user default off
user ${user} on >${pass} ~* &* +@all -flushall -flushdb -debug -config
EOF
}

write_replica_conf() {
  local outfile="$1" primary_host="$2" primary_port="$3" master_user="$4" master_pass="$5" maxmem="$6" policy="$7"
  cat > "${outfile}" <<EOF
replicaof ${primary_host} ${primary_port}
masteruser ${master_user}
masterauth ${master_pass}
appendonly yes
appendfsync everysec
maxmemory ${maxmem}
maxmemory-policy ${policy}
tcp-keepalive 300
aclfile /etc/redis/users.acl
EOF
  chmod 600 "${outfile}"
}

log "Synchronisation ACL avec .env.redis"
regenerate_acl cache-users.acl wise-eat-cache "${CACHE_REDIS_PASSWORD}"
regenerate_acl bull-users.acl wise-eat-bull "${BULL_REDIS_PASSWORD}"

mkdir -p data-cache data-bullmq
chown -R 999:999 data-cache data-bullmq
chown 999:999 cache-users.acl bull-users.acl
chmod 600 cache-users.acl bull-users.acl

COMPOSE_ARGS=(--env-file .env.redis)
if redis_cluster_b_enabled; then
  log "Redis : 1 primary + 2 réplicas (cache :${CACHE_REDIS_REPLICA_1_PORT}/:${CACHE_REDIS_REPLICA_2_PORT}, bull :${BULL_REDIS_REPLICA_1_PORT}/:${BULL_REDIS_REPLICA_2_PORT})"
  mkdir -p data-cache-replica-1 data-cache-replica-2 data-bullmq-replica-1 data-bullmq-replica-2
  chown -R 999:999 data-cache-replica-1 data-cache-replica-2 data-bullmq-replica-1 data-bullmq-replica-2
  write_replica_conf cache-replica-1.generated.conf wise-eat-redis-cache 6379 wise-eat-cache "${CACHE_REDIS_PASSWORD}" 1024mb allkeys-lru
  write_replica_conf cache-replica-2.generated.conf wise-eat-redis-cache 6379 wise-eat-cache "${CACHE_REDIS_PASSWORD}" 1024mb allkeys-lru
  write_replica_conf bull-replica-1.generated.conf wise-eat-redis-bullmq 6379 wise-eat-bull "${BULL_REDIS_PASSWORD}" 512mb noeviction
  write_replica_conf bull-replica-2.generated.conf wise-eat-redis-bullmq 6379 wise-eat-bull "${BULL_REDIS_PASSWORD}" 512mb noeviction
  chown 999:999 cache-replica-1.generated.conf cache-replica-2.generated.conf \
    bull-replica-1.generated.conf bull-replica-2.generated.conf
  COMPOSE_ARGS+=(--profile cluster-b)
  # Anciens conteneurs mono-réplica (migration)
  for old in wise-eat-redis-cache-replica wise-eat-redis-bullmq-replica; do
    docker rm -f "${old}" 2>/dev/null || true
  done
else
  log "Réplicas Redis désactivés (REDIS_CLUSTER_B_ENABLED=false)"
fi

log "Démarrage Redis Docker"
docker compose "${COMPOSE_ARGS[@]}" up -d
sleep 5
docker compose "${COMPOSE_ARGS[@]}" ps

ping_redis() {
  local container="$1" user="$2" pass="$3" label="$4"
  if docker exec "${container}" redis-cli --user "${user}" --pass "${pass}" ping 2>/dev/null | grep -q PONG; then
    log "OK  ${label}"
  else
    warn "FAIL ${label} — docker logs ${container}"
  fi
}

ping_redis wise-eat-redis-cache wise-eat-cache "${CACHE_REDIS_PASSWORD}" "redis-cache primary :6379"
ping_redis wise-eat-redis-bullmq wise-eat-bull "${BULL_REDIS_PASSWORD}" "redis-bullmq primary :6380"

if redis_cluster_b_enabled; then
  ping_redis wise-eat-redis-cache-replica-1 wise-eat-cache "${CACHE_REDIS_PASSWORD}" "redis-cache replica-1 :${CACHE_REDIS_REPLICA_1_PORT}"
  ping_redis wise-eat-redis-cache-replica-2 wise-eat-cache "${CACHE_REDIS_PASSWORD}" "redis-cache replica-2 :${CACHE_REDIS_REPLICA_2_PORT}"
  ping_redis wise-eat-redis-bullmq-replica-1 wise-eat-bull "${BULL_REDIS_PASSWORD}" "redis-bullmq replica-1 :${BULL_REDIS_REPLICA_1_PORT}"
  ping_redis wise-eat-redis-bullmq-replica-2 wise-eat-bull "${BULL_REDIS_PASSWORD}" "redis-bullmq replica-2 :${BULL_REDIS_REPLICA_2_PORT}"
fi

cat <<EOF

Primary (apps par défaut) :
  Cache   127.0.0.1:6379
  BullMQ  127.0.0.1:6380

Réplicas (lecture / failover manuel) :
  Cache   127.0.0.1:${CACHE_REDIS_REPLICA_1_PORT}  127.0.0.1:${CACHE_REDIS_REPLICA_2_PORT}
  BullMQ  127.0.0.1:${BULL_REDIS_REPLICA_1_PORT}  127.0.0.1:${BULL_REDIS_REPLICA_2_PORT}

Redis installé dans ${REDIS_DIR}
EOF
