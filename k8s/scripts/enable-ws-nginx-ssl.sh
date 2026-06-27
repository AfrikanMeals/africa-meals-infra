#!/usr/bin/env bash
# Certificat Let's Encrypt + HTTPS pour ws.wise-eat.com
# Usage : sudo STUNNEL_TLS_EMAIL=you@wise-eat.com ./enable-ws-nginx-ssl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

WS_WISE_EAT_DOMAIN="${WS_WISE_EAT_DOMAIN:-ws.wise-eat.com}"
EMAIL="${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}"

if [[ -z "${EMAIL}" ]]; then
  echo "Définir STUNNEL_TLS_EMAIL ou CERTBOT_EMAIL" >&2
  exit 1
fi

if [[ ! -f "/etc/letsencrypt/live/${WS_WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  log "Certificat LE pour ${WS_WISE_EAT_DOMAIN}..."
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${WS_WISE_EAT_DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
fi

"${SCRIPT_DIR}/install-ws-nginx.sh"
log "HTTPS ws actif : https://${WS_WISE_EAT_DOMAIN}/"
