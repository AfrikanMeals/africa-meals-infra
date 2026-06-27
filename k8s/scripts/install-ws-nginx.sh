#!/usr/bin/env bash
# Installe / met à jour le vhost nginx ws.wise-eat.com → k3s NodePort (30800).
# Usage : sudo ./install-ws-nginx.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

WS_WISE_EAT_DOMAIN="${WS_WISE_EAT_DOMAIN:-ws.wise-eat.com}"
WS_BACKEND_HOST="${WS_BACKEND_HOST:-127.0.0.1}"
WS_BACKEND_PORT="${WS_BACKEND_PORT:-30800}"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}"

SITE="/etc/nginx/sites-available/${WS_WISE_EAT_DOMAIN}.conf"
ENABLED="/etc/nginx/sites-enabled/${WS_WISE_EAT_DOMAIN}.conf"

export WS_WISE_EAT_DOMAIN WS_BACKEND_HOST WS_BACKEND_PORT CERTBOT_WEBROOT

if [[ -f "/etc/letsencrypt/live/${WS_WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  envsubst '${WS_WISE_EAT_DOMAIN} ${WS_BACKEND_HOST} ${WS_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/ws.wise-eat.com.https.conf.template" > "${SITE}"
  log "nginx HTTPS ws → ${WS_BACKEND_HOST}:${WS_BACKEND_PORT}"
else
  envsubst '${WS_WISE_EAT_DOMAIN} ${WS_BACKEND_HOST} ${WS_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/ws.wise-eat.com.http.conf.template" > "${SITE}"
  log "nginx HTTP ws (Certbot webroot) → ${WS_BACKEND_HOST}:${WS_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"

nginx -t
systemctl reload nginx

log "ws nginx actif — https://${WS_WISE_EAT_DOMAIN}/ → NodePort :${WS_BACKEND_PORT}"
