#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
stop_conflicting_webserver nginx

apt update
apt install -y nginx gettext-base libnginx-mod-stream

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}"

SITE="/etc/nginx/sites-available/${WISE_EAT_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${WISE_EAT_DOMAIN}"

if [[ -f "/etc/letsencrypt/live/${WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  render_template "${NGINX_CONF_SRC}/wise-eat.cloud.https.conf.template" "${SITE}"
  log "Config nginx HTTPS (certificat Let's Encrypt présent)"
else
  render_template "${NGINX_CONF_SRC}/wise-eat.cloud.http.conf.template" "${SITE}"
  log "Config nginx HTTP (Certbot webroot + proxy WS → ${WS_BACKEND_HOST}:${WS_BACKEND_PORT})"
fi

ln -sf "${SITE}" "${ENABLED}"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl restart nginx

log "nginx actif — http://${WISE_EAT_DOMAIN} → WS :${WS_BACKEND_PORT}"
systemctl status nginx --no-pager || true
