#!/usr/bin/env bash
# Reverse-proxy nginx → MinIO S3 API (storage.wise-eat.com) + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

CALLER_MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN-__CALLER_UNSET__}"
CALLER_MINIO_BACKEND_HOST="${MINIO_BACKEND_HOST-__CALLER_UNSET__}"
CALLER_MINIO_BACKEND_PORT="${MINIO_BACKEND_PORT-__CALLER_UNSET__}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
fi

MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
MINIO_BACKEND_HOST="${MINIO_BACKEND_HOST:-127.0.0.1}"
MINIO_BACKEND_PORT="${MINIO_BACKEND_PORT:-9000}"
MINIO_BUCKET="${MINIO_BUCKET:-wise-eat}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

if [[ "${CALLER_MINIO_STORAGE_DOMAIN}" != "__CALLER_UNSET__" ]]; then
  MINIO_STORAGE_DOMAIN="${CALLER_MINIO_STORAGE_DOMAIN}"
fi
if [[ "${CALLER_MINIO_BACKEND_HOST}" != "__CALLER_UNSET__" ]]; then
  MINIO_BACKEND_HOST="${CALLER_MINIO_BACKEND_HOST}"
fi
if [[ "${CALLER_MINIO_BACKEND_PORT}" != "__CALLER_UNSET__" ]]; then
  MINIO_BACKEND_PORT="${CALLER_MINIO_BACKEND_PORT}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${MINIO_STORAGE_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${MINIO_STORAGE_DOMAIN}"

render_minio_site() {
  local template="$1"
  export MINIO_STORAGE_DOMAIN MINIO_BACKEND_HOST MINIO_BACKEND_PORT CERTBOT_WEBROOT
  envsubst '${MINIO_STORAGE_DOMAIN} ${MINIO_BACKEND_HOST} ${MINIO_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${MINIO_STORAGE_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_minio_site "${NGINX_CONF_SRC}/storage.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS MinIO (${MINIO_STORAGE_DOMAIN})"
else
  render_minio_site "${NGINX_CONF_SRC}/storage.wise-eat.com.http.conf.template"
  log "Config nginx HTTP MinIO → ${MINIO_BACKEND_HOST}:${MINIO_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${MINIO_STORAGE_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${MINIO_STORAGE_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${MINIO_STORAGE_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-minio-storage-ssl.sh"
fi

log "MinIO public : https://${MINIO_STORAGE_DOMAIN}/${MINIO_BUCKET:-wise-eat}/"
log "Console MinIO : https://${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com} (basic auth nginx)"
