#!/usr/bin/env bash
# Certificat Let's Encrypt + HTTPS pour api.wise-eat.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

API_WISE_EAT_DOMAIN="${API_WISE_EAT_DOMAIN:-api.wise-eat.com}"
EMAIL="${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}"

if [[ -z "${EMAIL}" ]]; then
  echo "Définir STUNNEL_TLS_EMAIL ou CERTBOT_EMAIL" >&2
  exit 1
fi

if [[ ! -f "/etc/letsencrypt/live/${API_WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  log "Certificat LE pour ${API_WISE_EAT_DOMAIN}..."
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${API_WISE_EAT_DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
fi

"${SCRIPT_DIR}/install-api-nginx.sh"
log "HTTPS api actif : https://${API_WISE_EAT_DOMAIN}/"
