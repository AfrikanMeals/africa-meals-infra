#!/usr/bin/env bash
# Copie les certs Let's Encrypt vers /etc/stunnel/certs/ (permissions stunnel4).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

LE_DIR="/etc/letsencrypt/live/${REDIS_TLS_DOMAIN}"
DEST="/etc/stunnel/certs"

[[ -f "${LE_DIR}/fullchain.pem" && -f "${LE_DIR}/privkey.pem" ]] || \
  die "Certificat absent : ${LE_DIR} — lancer : STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh redis-stunnel-cert"

mkdir -p "${DEST}"
cp -L "${LE_DIR}/fullchain.pem" "${DEST}/fullchain.pem"
cp -L "${LE_DIR}/privkey.pem" "${DEST}/privkey.pem"

chown root:stunnel4 "${DEST}/fullchain.pem" "${DEST}/privkey.pem"
chmod 644 "${DEST}/fullchain.pem"
chmod 640 "${DEST}/privkey.pem"

log "Certs Stunnel synchronisés (${REDIS_TLS_DOMAIN}) → ${DEST}/"

if [[ "${STUNNEL_SKIP_RESTART:-}" == "1" ]]; then
  exit 0
fi

stunnel_sync_conf_d
stunnel_restart_or_die
