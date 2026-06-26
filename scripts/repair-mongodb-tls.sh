#!/usr/bin/env bash
# Répare Stunnel MongoDB TLS (db.wise-eat.com:27018) + resync Redis/Memcached.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation Stunnel (MongoDB :27018 + Redis/Memcached) ==="

if [[ ! -f "/etc/letsencrypt/live/${MONGO_TLS_DOMAIN:-db.wise-eat.com}/fullchain.pem" ]]; then
  die "Certificat db.wise-eat.com absent — sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh mongodb-tls"
fi

apt install -y stunnel4 2>/dev/null || true
ensure_stunnel_runtime

if [[ -f "${INFRA_ROOT}/scripts/sync-stunnel-certs.sh" ]]; then
  STUNNEL_SKIP_RESTART=1 bash "${SCRIPT_DIR}/sync-stunnel-certs.sh" 2>/dev/null || true
fi
STUNNEL_SKIP_RESTART=1 bash "${SCRIPT_DIR}/sync-mongodb-stunnel-certs.sh"

stunnel_sync_conf_d
systemctl enable stunnel4
stunnel_restart_or_die

MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"
if ss -tlnp 2>/dev/null | grep -q ":${MONGO_TLS_PORT}"; then
  log "OK  MongoDB TLS :${MONGO_TLS_PORT}"
else
  warn "MongoDB TLS :${MONGO_TLS_PORT} absent"
fi

if ss -tlnp 2>/dev/null | grep -q ':6381'; then
  log "OK  Redis Stunnel :6381"
else
  warn "Redis Stunnel :6381 absent — sudo ./install.sh stunnel"
fi

log "Test : docker exec wise-eat-mongo-1 mongosh --eval 'db.adminCommand({ping:1})'"
