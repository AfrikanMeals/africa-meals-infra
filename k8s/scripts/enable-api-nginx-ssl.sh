#!/usr/bin/env bash
# Certificat Let's Encrypt + HTTPS pour api.wise-eat.com → k3s NodePort :30900
#
# Usage :
#   sudo STUNNEL_TLS_EMAIL=help@wise-eat.com k8s/scripts/enable-api-nginx-ssl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/certbot.sh
source "${INFRA_ROOT}/scripts/lib/certbot.sh"

require_root

API_WISE_EAT_DOMAIN="${API_WISE_EAT_DOMAIN:-api.wise-eat.com}"

[[ -n "${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}" ]] || \
  die "Définir STUNNEL_TLS_EMAIL ou CERTBOT_EMAIL"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_letsencrypt_nginx_tls_files

if ! cert_exists "${API_WISE_EAT_DOMAIN}"; then
  log "Site HTTP temporaire (validation ACME webroot)..."
  "${SCRIPT_DIR}/install-api-nginx.sh"
  issue_le_cert "${API_WISE_EAT_DOMAIN}"
fi

"${SCRIPT_DIR}/install-api-nginx.sh"

log "HTTPS API actif : https://${API_WISE_EAT_DOMAIN}/api/health"
log "Vérifier : curl -sI https://${API_WISE_EAT_DOMAIN}/api/health | head -5"
