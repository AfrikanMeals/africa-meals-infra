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

if docker ps --format '{{.Names}}' | grep -q '^wise-eat-redis-cache$'; then
  log "Redis cache : OK"
else
  warn "Redis cache absent — lancer : sudo ./install.sh redis"
fi

if docker ps --format '{{.Names}}' | grep -q '^wise-eat-memcached$'; then
  log "Memcached : OK"
else
  warn "Memcached absent — lancer : sudo ./install.sh memcached"
fi

bash "${SCRIPT_DIR}/install-monitoring.sh"

echo ""
log "Diagnostic :"
bash "${SCRIPT_DIR}/verify-monitoring.sh"
