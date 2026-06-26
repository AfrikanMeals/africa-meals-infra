#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
MONGO_ADMIN_DOMAIN="${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
MONGO_ADMIN_BACKEND_HOST="${MONGO_ADMIN_BACKEND_HOST:-127.0.0.1}"
MONGO_ADMIN_BACKEND_PORT="${MONGO_ADMIN_BACKEND_PORT:-8081}"

[[ -f "/etc/letsencrypt/live/${MONGO_ADMIN_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${MONGO_ADMIN_DOMAIN}"

if [[ -f "${MONGODB_ENV}" ]]; then
  set -a && source "${MONGODB_ENV}" && set +a
  MONGO_ADMIN_BACKEND_PORT="${MONGO_DBGATE_PORT:-${MONGO_EXPRESS_PORT:-${MONGO_ADMIN_BACKEND_PORT}}}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_mongodb_admin_basic_auth_file

SITE="/etc/nginx/sites-available/${MONGO_ADMIN_DOMAIN}"
export MONGO_ADMIN_DOMAIN MONGO_ADMIN_BACKEND_HOST MONGO_ADMIN_BACKEND_PORT \
  CERTBOT_WEBROOT MONGO_ADMIN_HTASSWD_FILE
envsubst '${MONGO_ADMIN_DOMAIN} ${MONGO_ADMIN_BACKEND_HOST} ${MONGO_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${MONGO_ADMIN_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/data.wise-eat.com.https.conf.template" > "${SITE}"

nginx_test_and_reload
log "nginx HTTPS MongoDB Admin activé — https://${MONGO_ADMIN_DOMAIN}"
