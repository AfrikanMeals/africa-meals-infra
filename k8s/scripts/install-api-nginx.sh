#!/usr/bin/env bash
# Installe / met à jour le vhost nginx api.wise-eat.com → k3s NodePort (30900).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

API_WISE_EAT_DOMAIN="${API_WISE_EAT_DOMAIN:-api.wise-eat.com}"
API_BACKEND_HOST="${API_BACKEND_HOST:-127.0.0.1}"
API_BACKEND_PORT="${API_BACKEND_PORT:-30900}"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}"

SITE="/etc/nginx/sites-available/${API_WISE_EAT_DOMAIN}.conf"
ENABLED="/etc/nginx/sites-enabled/${API_WISE_EAT_DOMAIN}.conf"

export API_WISE_EAT_DOMAIN API_BACKEND_HOST API_BACKEND_PORT CERTBOT_WEBROOT

if [[ -f "/etc/letsencrypt/live/${API_WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  envsubst '${API_WISE_EAT_DOMAIN} ${API_BACKEND_HOST} ${API_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/api.wise-eat.com.https.conf.template" > "${SITE}"
  log "nginx HTTPS api → ${API_BACKEND_HOST}:${API_BACKEND_PORT}"
else
  envsubst '${API_WISE_EAT_DOMAIN} ${API_BACKEND_HOST} ${API_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/api.wise-eat.com.http.conf.template" > "${SITE}"
  log "nginx HTTP api (Certbot webroot) → ${API_BACKEND_HOST}:${API_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"

nginx -t
systemctl reload nginx

log "api nginx actif — https://${API_WISE_EAT_DOMAIN}/ → NodePort :${API_BACKEND_PORT}"
