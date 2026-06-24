#!/usr/bin/env bash
# Reverse-proxy nginx → Grafana (console.wise-eat.com) + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

GRAFANA_CONSOLE_DOMAIN="${GRAFANA_CONSOLE_DOMAIN:-console.wise-eat.com}"
GRAFANA_BACKEND_HOST="${GRAFANA_BACKEND_HOST:-127.0.0.1}"
GRAFANA_BACKEND_PORT="${GRAFANA_BACKEND_PORT:-3000}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${GRAFANA_CONSOLE_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${GRAFANA_CONSOLE_DOMAIN}"

render_grafana_site() {
  local template="$1"
  export GRAFANA_CONSOLE_DOMAIN GRAFANA_BACKEND_HOST GRAFANA_BACKEND_PORT CERTBOT_WEBROOT
  envsubst '${GRAFANA_CONSOLE_DOMAIN} ${GRAFANA_BACKEND_HOST} ${GRAFANA_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${GRAFANA_CONSOLE_DOMAIN}/fullchain.pem" ]]; then
  render_grafana_site "${NGINX_CONF_SRC}/console.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS Grafana (${GRAFANA_CONSOLE_DOMAIN})"
else
  render_grafana_site "${NGINX_CONF_SRC}/console.wise-eat.com.http.conf.template"
  log "Config nginx HTTP Grafana → ${GRAFANA_BACKEND_HOST}:${GRAFANA_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${GRAFANA_CONSOLE_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${GRAFANA_CONSOLE_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${GRAFANA_CONSOLE_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-grafana-console-ssl.sh"
fi

log "Grafana public : https://${GRAFANA_CONSOLE_DOMAIN} (auth Grafana obligatoire)"
log "Vérifier monitoring : GRAFANA_ROOT_URL=https://${GRAFANA_CONSOLE_DOMAIN}/"
