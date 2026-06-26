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

bash "${SCRIPT_DIR}/sync-mongodb-stunnel-certs.sh"

cp "${INFRA_ROOT}/mongodb/stunnel/mongodb-tls.conf" /etc/stunnel/conf.d/

if ! grep -q 'include = /etc/stunnel/conf.d' /etc/stunnel/stunnel.conf 2>/dev/null; then
  cat >> /etc/stunnel/stunnel.conf <<'EOF'

; Wise Eat
setuid = stunnel4
setgid = stunnel4
pid = /var/run/stunnel4/stunnel.pid
include = /etc/stunnel/conf.d
EOF
fi

systemctl enable stunnel4
stunnel_restart_or_die

ensure_ufw_ipv6_enabled
ufw_allow_tcp_port "${MONGO_TLS_PORT}" "Stunnel MongoDB TLS :${MONGO_TLS_PORT}"
if command -v ufw >/dev/null 2>&1; then
  ufw reload
fi

log "MongoDB TLS actif : ${MONGO_TLS_DOMAIN}:${MONGO_TLS_PORT} → 127.0.0.1:27017 (v4 + v6)"
log "URI : mongodb://USER:PASS@${MONGO_TLS_DOMAIN}:${MONGO_TLS_PORT}/DB?replicaSet=rs0&tls=true"
