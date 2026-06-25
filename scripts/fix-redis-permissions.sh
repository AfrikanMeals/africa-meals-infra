#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
[[ -d "${REDIS_DIR}" ]] || die "Redis absent — lancer : install.sh redis"

cd "${REDIS_DIR}"

for f in cache-users.acl bull-users.acl; do
  if [[ -f "${f}" ]]; then
    chown 999:999 "${f}"
    chmod 600 "${f}"
    log "OK ${f} → 999:999"
  else
    warn "${f} absent — lancer : install.sh redis"
  fi
done

mkdir -p data-cache data-bullmq
chown -R 999:999 data-cache data-bullmq
log "OK data-cache data-bullmq → 999:999"

if redis_cluster_b_enabled; then
  for f in cache-replica.generated.conf bull-replica.generated.conf; do
    if [[ -f "${f}" ]]; then
      chown 999:999 "${f}"
      chmod 600 "${f}"
    fi
  done
  mkdir -p data-cache-replica data-bullmq-replica
  chown -R 999:999 data-cache-replica data-bullmq-replica
  log "OK data-cache-replica data-bullmq-replica → 999:999"
fi

if command -v docker >/dev/null 2>&1 && [[ -f docker-compose.yml ]]; then
  COMPOSE_ARGS=(--env-file .env.redis)
  if redis_cluster_b_enabled; then
    COMPOSE_ARGS+=(--profile cluster-b)
  fi
  docker compose "${COMPOSE_ARGS[@]}" up -d
  sleep 2
  docker compose "${COMPOSE_ARGS[@]}" ps
fi
