#!/usr/bin/env bash
# Répare exporters Prometheus (redis_up / memcached_up) après changement réseau ou mots de passe.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation stack monitoring ==="

ensure_docker
ensure_wise_eat_infra_network

redis_running() {
  docker ps --format '{{.Names}}' | grep -q '^wise-eat-redis-cache$'
}

if redis_running; then
  log "Redis cache : OK"
else
  warn "Redis cache absent — installation Redis"
  bash "${SCRIPT_DIR}/install-redis.sh"
fi

if docker ps --format '{{.Names}}' | grep -q '^wise-eat-memcached$'; then
  log "Memcached : OK"
else
  warn "Memcached absent — installation Memcached"
  bash "${SCRIPT_DIR}/install-memcached.sh"
fi

if docker ps --format '{{.Names}}' | grep -q '^wise-eat-minio$'; then
  log "MinIO : OK"
else
  warn "MinIO absent — installation MinIO (métriques Grafana)"
  bash "${SCRIPT_DIR}/install-minio.sh"
fi

bash "${SCRIPT_DIR}/install-monitoring.sh"

log "Attente démarrage Prometheus (15s max)…"
for _ in $(seq 1 15); do
  if curl -sf 'http://127.0.0.1:9090/-/ready' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo ""
log "Diagnostic :"
bash "${SCRIPT_DIR}/verify-monitoring.sh" || true

if ! redis_running; then
  echo ""
  warn "Redis toujours arrêté — vérifier : cd ${REDIS_DIR} && docker compose ps && docker compose logs --tail=30"
fi
