#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

CALLER_MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN-__CALLER_UNSET__}"
CALLER_MINIO_BACKEND_HOST="${MINIO_BACKEND_HOST-__CALLER_UNSET__}"
CALLER_MINIO_BACKEND_PORT="${MINIO_BACKEND_PORT-__CALLER_UNSET__}"

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
fi

MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
MINIO_BACKEND_HOST="${MINIO_BACKEND_HOST:-127.0.0.1}"
MINIO_BACKEND_PORT="${MINIO_BACKEND_PORT:-9000}"

if [[ "${CALLER_MINIO_STORAGE_DOMAIN}" != "__CALLER_UNSET__" ]]; then
  MINIO_STORAGE_DOMAIN="${CALLER_MINIO_STORAGE_DOMAIN}"
fi
if [[ "${CALLER_MINIO_BACKEND_HOST}" != "__CALLER_UNSET__" ]]; then
  MINIO_BACKEND_HOST="${CALLER_MINIO_BACKEND_HOST}"
fi
if [[ "${CALLER_MINIO_BACKEND_PORT}" != "__CALLER_UNSET__" ]]; then
  MINIO_BACKEND_PORT="${CALLER_MINIO_BACKEND_PORT}"
fi

[[ -f "/etc/letsencrypt/live/${MINIO_STORAGE_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${MINIO_STORAGE_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files

SITE="/etc/nginx/sites-available/${MINIO_STORAGE_DOMAIN}"
export MINIO_STORAGE_DOMAIN MINIO_BACKEND_HOST MINIO_BACKEND_PORT CERTBOT_WEBROOT
envsubst '${MINIO_STORAGE_DOMAIN} ${MINIO_BACKEND_HOST} ${MINIO_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
  < "${NGINX_CONF_SRC}/storage.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS MinIO activé — https://${MINIO_STORAGE_DOMAIN}"
