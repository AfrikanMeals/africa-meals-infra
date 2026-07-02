#!/usr/bin/env bash
# Reverse-proxy nginx → Matomo (analytics.wise-eat.com) + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

MATOMO_DOMAIN="${MATOMO_DOMAIN:-analytics.wise-eat.com}"
MATOMO_BACKEND_HOST="${MATOMO_BACKEND_HOST:-127.0.0.1}"
MATOMO_BACKEND_PORT="${MATOMO_BACKEND_PORT:-8089}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${MATOMO_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${MATOMO_DOMAIN}"

render_matomo_site() {
  local template="$1"
  export MATOMO_DOMAIN MATOMO_BACKEND_HOST MATOMO_BACKEND_PORT CERTBOT_WEBROOT
  envsubst '${MATOMO_DOMAIN} ${MATOMO_BACKEND_HOST} ${MATOMO_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${MATOMO_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_matomo_site "${NGINX_CONF_SRC}/analytics.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS Matomo (${MATOMO_DOMAIN})"
else
  render_matomo_site "${NGINX_CONF_SRC}/analytics.wise-eat.com.http.conf.template"
  log "Config nginx HTTP Matomo → ${MATOMO_BACKEND_HOST}:${MATOMO_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${MATOMO_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${MATOMO_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${MATOMO_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-matomo-ssl.sh"
fi

log "Matomo public : https://${MATOMO_DOMAIN} (auth Matomo obligatoire pour l'admin)"
