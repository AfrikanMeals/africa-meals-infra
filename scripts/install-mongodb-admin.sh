#!/usr/bin/env bash
# Reverse-proxy nginx → Mongo Express (data.wise-eat.com) + basic auth + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

MONGO_ADMIN_DOMAIN="${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
MONGO_ADMIN_BACKEND_HOST="${MONGO_ADMIN_BACKEND_HOST:-127.0.0.1}"
MONGO_ADMIN_BACKEND_PORT="${MONGO_ADMIN_BACKEND_PORT:-8081}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${MONGODB_ENV}" ]]; then
  set -a && source "${MONGODB_ENV}" && set +a
  MONGO_ADMIN_BACKEND_PORT="${MONGO_EXPRESS_PORT:-${MONGO_ADMIN_BACKEND_PORT}}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_mongodb_admin_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${MONGO_ADMIN_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${MONGO_ADMIN_DOMAIN}"

render_mongodb_admin_site() {
  local template="$1"
  export MONGO_ADMIN_DOMAIN MONGO_ADMIN_BACKEND_HOST MONGO_ADMIN_BACKEND_PORT \
    CERTBOT_WEBROOT MONGO_ADMIN_HTASSWD_FILE
  envsubst '${MONGO_ADMIN_DOMAIN} ${MONGO_ADMIN_BACKEND_HOST} ${MONGO_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${MONGO_ADMIN_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${MONGO_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_mongodb_admin_site "${NGINX_CONF_SRC}/data.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS MongoDB Admin (${MONGO_ADMIN_DOMAIN})"
else
  render_mongodb_admin_site "${NGINX_CONF_SRC}/data.wise-eat.com.http.conf.template"
  log "Config nginx HTTP MongoDB Admin → ${MONGO_ADMIN_BACKEND_HOST}:${MONGO_ADMIN_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx_test_and_reload

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${MONGO_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${MONGO_ADMIN_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${MONGO_ADMIN_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-mongodb-admin-ssl.sh"
fi

log "MongoDB Admin public : https://${MONGO_ADMIN_DOMAIN}"
log "  Basic auth nginx : ${MONGO_ADMIN_BASIC_AUTH_USER:-mongo-admin}"
log "    Mot de passe : MONGO_ADMIN_BASIC_AUTH_PASSWORD dans ${MONGODB_ENV}"
