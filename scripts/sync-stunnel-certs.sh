#!/usr/bin/env bash
# Copie les certs Let's Encrypt vers /etc/stunnel/certs/ (permissions stunnel4).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STUNNEL_TLS_DOMAIN="${STUNNEL_TLS_DOMAIN:-wise-eat.cloud}"
LE_DIR="/etc/letsencrypt/live/${STUNNEL_TLS_DOMAIN}"
DEST="/etc/stunnel/certs"

[[ -f "${LE_DIR}/fullchain.pem" && -f "${LE_DIR}/privkey.pem" ]] || \
  die "Certificat absent : ${LE_DIR} — lancer : STUNNEL_TLS_EMAIL=… ./install.sh certbot"

mkdir -p "${DEST}"
cp -L "${LE_DIR}/fullchain.pem" "${DEST}/fullchain.pem"
cp -L "${LE_DIR}/privkey.pem" "${DEST}/privkey.pem"

chown root:stunnel4 "${DEST}/fullchain.pem" "${DEST}/privkey.pem"
chmod 644 "${DEST}/fullchain.pem"
chmod 640 "${DEST}/privkey.pem"

log "Certs Stunnel synchronisés (${STUNNEL_TLS_DOMAIN}) → ${DEST}/"

if systemctl is-active stunnel4 >/dev/null 2>&1; then
  systemctl restart stunnel4
  log "stunnel4 redémarré"
fi
