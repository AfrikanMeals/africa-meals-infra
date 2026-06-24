#!/usr/bin/env bash
# Certificat Let's Encrypt pour Redis Stunnel (cache.wise-eat.com) + sync → /etc/stunnel/certs/
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/certbot.sh
source "${SCRIPT_DIR}/lib/certbot.sh"

require_root

STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"
[[ -n "${STUNNEL_TLS_EMAIL}" ]] || \
  die "STUNNEL_TLS_EMAIL requis — ex. STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh redis-stunnel-cert"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"
systemctl is-active nginx >/dev/null 2>&1 || die "nginx doit être actif sur :80"

apt install -y certbot 2>/dev/null || true

log "=== Webroot ACME pour ${REDIS_TLS_DOMAIN} ==="
bash "${SCRIPT_DIR}/install-redis-tls-acme.sh"

log "=== Certificat Let's Encrypt (${REDIS_TLS_DOMAIN}) ==="
issue_le_cert "${REDIS_TLS_DOMAIN}"

log "=== Sync Stunnel ==="
bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"

if systemctl is-active stunnel4 >/dev/null 2>&1; then
  systemctl restart stunnel4
  log "stunnel4 redémarré"
else
  warn "stunnel4 inactif — lancer : sudo ./install.sh stunnel"
fi

log "Redis TLS : rediss://<user>:<pass>@${REDIS_TLS_DOMAIN}:6381 (cert LE)"
