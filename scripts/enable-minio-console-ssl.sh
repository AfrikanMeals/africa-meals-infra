#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
MINIO_CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
MINIO_CONSOLE_BACKEND_HOST="${MINIO_CONSOLE_BACKEND_HOST:-127.0.0.1}"
MINIO_CONSOLE_BACKEND_PORT="${MINIO_CONSOLE_BACKEND_PORT:-9001}"

[[ -f "/etc/letsencrypt/live/${MINIO_CONSOLE_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${MINIO_CONSOLE_DOMAIN}"

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
fi

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_minio_console_basic_auth_file

SITE="/etc/nginx/sites-available/${MINIO_CONSOLE_DOMAIN}"
export MINIO_CONSOLE_DOMAIN MINIO_CONSOLE_BACKEND_HOST MINIO_CONSOLE_BACKEND_PORT \
  CERTBOT_WEBROOT MINIO_CONSOLE_HTASSWD_FILE
envsubst '${MINIO_CONSOLE_DOMAIN} ${MINIO_CONSOLE_BACKEND_HOST} ${MINIO_CONSOLE_BACKEND_PORT} ${CERTBOT_WEBROOT} ${MINIO_CONSOLE_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/cdn.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS MinIO Console activé — https://${MINIO_CONSOLE_DOMAIN}"
