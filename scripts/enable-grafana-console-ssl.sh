#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
GRAFANA_CONSOLE_DOMAIN="${GRAFANA_CONSOLE_DOMAIN:-console.wise-eat.com}"
GRAFANA_BACKEND_HOST="${GRAFANA_BACKEND_HOST:-127.0.0.1}"
GRAFANA_BACKEND_PORT="${GRAFANA_BACKEND_PORT:-3000}"

[[ -f "/etc/letsencrypt/live/${GRAFANA_CONSOLE_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${GRAFANA_CONSOLE_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

SITE="/etc/nginx/sites-available/${GRAFANA_CONSOLE_DOMAIN}"
GRAFANA_CONSOLE_DOMAIN GRAFANA_BACKEND_HOST GRAFANA_BACKEND_PORT CERTBOT_WEBROOT \
  envsubst '${GRAFANA_CONSOLE_DOMAIN} ${GRAFANA_BACKEND_HOST} ${GRAFANA_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
  < "${NGINX_CONF_SRC}/console.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS Grafana activé — https://${GRAFANA_CONSOLE_DOMAIN}"
