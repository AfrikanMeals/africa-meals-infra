#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
stop_conflicting_webserver apache

apt update
apt install -y apache2 gettext-base

a2enmod proxy proxy_http proxy_wstunnel rewrite headers ssl 2>/dev/null || true

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}"

SITE="/etc/apache2/sites-available/${WISE_EAT_DOMAIN}.conf"

if [[ -f "/etc/letsencrypt/live/${WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  render_template "${APACHE_CONF_SRC}/wise-eat.cloud.https.conf.template" "${SITE}"
  log "Config apache HTTPS (certificat Let's Encrypt présent)"
else
  render_template "${APACHE_CONF_SRC}/wise-eat.cloud.http.conf.template" "${SITE}"
  log "Config apache HTTP (Certbot webroot + proxy WS → ${WS_BACKEND_HOST}:${WS_BACKEND_PORT})"
fi

a2dissite 000-default.conf 2>/dev/null || true
a2ensite "${WISE_EAT_DOMAIN}.conf"

apache2ctl configtest
systemctl enable apache2
systemctl restart apache2

log "apache2 actif — http://${WISE_EAT_DOMAIN} → WS :${WS_BACKEND_PORT}"
systemctl status apache2 --no-pager || true
