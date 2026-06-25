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
CACHE_REDIS_REPLICA_PORT=6371
BULL_REDIS_REPLICA_PORT=6390
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
PROFILE="$(wise_eat_compose_profiles || true)"
if redis_cluster_b_enabled; then
  log "Cluster B Redis : réplicas cache :${CACHE_REDIS_REPLICA_PORT:-6371} bull :${BULL_REDIS_REPLICA_PORT:-6390}"
  mkdir -p data-cache-replica data-bullmq-replica
  chown -R 999:999 data-cache-replica data-bullmq-replica
  write_replica_conf cache-replica.generated.conf wise-eat-redis-cache 6379 wise-eat-cache "${CACHE_REDIS_PASSWORD}" 1024mb allkeys-lru
  write_replica_conf bull-replica.generated.conf wise-eat-redis-bullmq 6379 wise-eat-bull "${BULL_REDIS_PASSWORD}" 512mb noeviction
  chown 999:999 cache-replica.generated.conf bull-replica.generated.conf
  COMPOSE_ARGS+=(--profile cluster-b)
else
  log "Cluster B Redis désactivé (REDIS_CLUSTER_B_ENABLED=false)"
fi

log "Démarrage Redis Docker"
docker compose "${COMPOSE_ARGS[@]}" up -d
sleep 4
docker compose "${COMPOSE_ARGS[@]}" ps

if docker exec wise-eat-redis-cache redis-cli --user wise-eat-cache --pass "${CACHE_REDIS_PASSWORD}" ping | grep -q PONG; then
  log "redis-cache (cluster A) : PONG :6379"
else
  warn "redis-cache ping échoué — voir docker logs wise-eat-redis-cache"
fi
if docker exec wise-eat-redis-bullmq redis-cli --user wise-eat-bull --pass "${BULL_REDIS_PASSWORD}" ping | grep -q PONG; then
  log "redis-bullmq (cluster A) : PONG :6380"
else
  warn "redis-bullmq ping échoué — voir docker logs wise-eat-redis-bullmq"
fi

if redis_cluster_b_enabled; then
  if docker exec wise-eat-redis-cache-replica redis-cli --user wise-eat-cache --pass "${CACHE_REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
    log "redis-cache-replica (cluster B) : PONG :${CACHE_REDIS_REPLICA_PORT:-6371}"
  else
    warn "redis-cache-replica injoignable — docker logs wise-eat-redis-cache-replica"
  fi
  if docker exec wise-eat-redis-bullmq-replica redis-cli --user wise-eat-bull --pass "${BULL_REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
    log "redis-bullmq-replica (cluster B) : PONG :${BULL_REDIS_REPLICA_PORT:-6390}"
  else
    warn "redis-bullmq-replica injoignable — docker logs wise-eat-redis-bullmq-replica"
  fi
fi

cat <<EOF

Cluster A (primary — apps par défaut) :
  Cache   127.0.0.1:6379  user wise-eat-cache
  BullMQ  127.0.0.1:6380  user wise-eat-bull

Cluster B (réplicas lecture — bascule manuelle si primary down) :
  Cache   127.0.0.1:${CACHE_REDIS_REPLICA_PORT:-6371}
  BullMQ  127.0.0.1:${BULL_REDIS_REPLICA_PORT:-6390}

Failover manuel API/WS : pointer REDIS_PORT / BULLMQ_REDIS_PORT vers cluster B.
Pas de bascule automatique sur un seul VPS.

Redis installé dans ${REDIS_DIR}
EOF
