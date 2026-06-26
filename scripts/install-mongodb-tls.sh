#!/usr/bin/env bash
# Stunnel TLS MongoDB — db.wise-eat.com:27018 → 127.0.0.1:27017
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${MONGODB_ENV}" ]]; then
  set -a && source "${MONGODB_ENV}" && set +a
  MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
  MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"
fi

apt install -y stunnel4 2>/dev/null || true
ensure_stunnel_runtime
mkdir -p /etc/stunnel/conf.d /etc/stunnel/mongodb

if [[ ! -f "/etc/letsencrypt/live/${MONGO_TLS_DOMAIN}/fullchain.pem" ]]; then
  if [[ -n "${STUNNEL_TLS_EMAIL}" ]]; then
    command -v nginx >/dev/null 2>&1 || die "nginx requis pour ACME"
    bash "${SCRIPT_DIR}/install-mongodb-tls-acme.sh"
    apt install -y certbot 2>/dev/null || true
    certbot certonly --webroot \
      -w "${CERTBOT_WEBROOT}" \
      -d "${MONGO_TLS_DOMAIN}" \
      --email "${STUNNEL_TLS_EMAIL}" \
      --agree-tos \
      --non-interactive \
      --keep-until-expiring
  else
    die "Certificat absent pour ${MONGO_TLS_DOMAIN} — STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh mongodb-tls"
  fi
fi

# Sync certs sans redémarrer stunnel (config pas encore à jour).
STUNNEL_SKIP_RESTART=1 bash "${SCRIPT_DIR}/sync-mongodb-stunnel-certs.sh"

stunnel_sync_conf_d
systemctl enable stunnel4
stunnel_restart_or_die

ensure_ufw_ipv6_enabled
ufw_allow_tcp_port "${MONGO_TLS_PORT}" "Stunnel MongoDB TLS :${MONGO_TLS_PORT}"
if command -v ufw >/dev/null 2>&1; then
  ufw reload
fi

if ss -tlnp 2>/dev/null | grep -q ":${MONGO_TLS_PORT}"; then
  log "OK  port ${MONGO_TLS_PORT} actif"
else
  warn "Port ${MONGO_TLS_PORT} absent — journalctl -u stunnel4 -n 50"
fi

log "MongoDB TLS actif : ${MONGO_TLS_DOMAIN}:${MONGO_TLS_PORT} → 127.0.0.1:27017 (v4 + v6)"
log "URI : mongodb://USER:PASS@${MONGO_TLS_DOMAIN}:${MONGO_TLS_PORT}/DB?replicaSet=rs0&tls=true&directConnection=true"
