#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
MATOMO_DOMAIN="${MATOMO_DOMAIN:-analytics.wise-eat.com}"
MATOMO_BACKEND_HOST="${MATOMO_BACKEND_HOST:-127.0.0.1}"
MATOMO_BACKEND_PORT="${MATOMO_BACKEND_PORT:-8089}"

[[ -f "/etc/letsencrypt/live/${MATOMO_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${MATOMO_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files

SITE="/etc/nginx/sites-available/${MATOMO_DOMAIN}"
export MATOMO_DOMAIN MATOMO_BACKEND_HOST MATOMO_BACKEND_PORT CERTBOT_WEBROOT
envsubst '${MATOMO_DOMAIN} ${MATOMO_BACKEND_HOST} ${MATOMO_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
  < "${NGINX_CONF_SRC}/analytics.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS Matomo activé — https://${MATOMO_DOMAIN}"
