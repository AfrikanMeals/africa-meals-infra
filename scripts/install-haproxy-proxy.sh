#!/usr/bin/env bash
# nginx → HAProxy stats (proxy.wise-eat.com) + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

HAPROXY_PROXY_DOMAIN="${HAPROXY_PROXY_DOMAIN:-proxy.wise-eat.com}"
HAPROXY_STATS_HOST="${HAPROXY_STATS_HOST:-127.0.0.1}"
HAPROXY_STATS_PORT="${HAPROXY_STATS_PORT:-8404}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_haproxy_proxy_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${HAPROXY_PROXY_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${HAPROXY_PROXY_DOMAIN}"

render_proxy_site() {
  local template="$1"
  export HAPROXY_PROXY_DOMAIN HAPROXY_STATS_HOST HAPROXY_STATS_PORT \
    CERTBOT_WEBROOT HAPROXY_PROXY_HTASSWD_FILE
  envsubst '${HAPROXY_PROXY_DOMAIN} ${HAPROXY_STATS_HOST} ${HAPROXY_STATS_PORT} ${CERTBOT_WEBROOT} ${HAPROXY_PROXY_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${HAPROXY_PROXY_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_proxy_site "${NGINX_CONF_SRC}/proxy.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS HAProxy UI (${HAPROXY_PROXY_DOMAIN})"
else
  render_proxy_site "${NGINX_CONF_SRC}/proxy.wise-eat.com.http.conf.template"
  log "Config nginx HTTP HAProxy UI → ${HAPROXY_STATS_HOST}:${HAPROXY_STATS_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${HAPROXY_PROXY_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${HAPROXY_PROXY_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${HAPROXY_PROXY_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-haproxy-proxy-ssl.sh"
fi

CRED_FILE="/etc/wise-eat/haproxy-proxy.env"
if [[ -f "${CRED_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CRED_FILE}"
  log "HAProxy UI : https://${HAPROXY_PROXY_DOMAIN}/stats — user=${HAPROXY_PROXY_BASIC_AUTH_USER:-haproxy}"
  log "Mot de passe : voir ${CRED_FILE} (chmod 600)"
else
  log "HAProxy UI : https://${HAPROXY_PROXY_DOMAIN}/stats (basic auth htpasswd)"
fi
