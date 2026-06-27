#!/usr/bin/env bash
# Certificat Let's Encrypt + HTTPS pour k8s.wise-eat.com (Headlamp).
# Usage : sudo STUNNEL_TLS_EMAIL=you@wise-eat.com ./enable-k8s-nginx-ssl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

K8S_DASHBOARD_DOMAIN="${K8S_DASHBOARD_DOMAIN:-k8s.wise-eat.com}"
EMAIL="${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}"

if [[ -z "${EMAIL}" ]]; then
  echo "Définir STUNNEL_TLS_EMAIL ou CERTBOT_EMAIL" >&2
  exit 1
fi

if [[ ! -f "/etc/letsencrypt/live/${K8S_DASHBOARD_DOMAIN}/fullchain.pem" ]]; then
  log "Certificat LE pour ${K8S_DASHBOARD_DOMAIN}..."
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${K8S_DASHBOARD_DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
fi

"${SCRIPT_DIR}/install-k8s-nginx.sh"
log "HTTPS k8s actif : https://${K8S_DASHBOARD_DOMAIN}/"
