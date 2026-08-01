#!/usr/bin/env bash
# Active nginx HTTPS pour RedisInsight une fois le certificat LE présent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
REDIS_ADMIN_DOMAIN="${REDIS_ADMIN_DOMAIN:-redis.wise-eat.com}"
REDIS_ADMIN_BACKEND_HOST="${REDIS_ADMIN_BACKEND_HOST:-127.0.0.1}"
REDIS_ADMIN_BACKEND_PORT="${REDIS_ADMIN_BACKEND_PORT:-5540}"

[[ -f "/etc/letsencrypt/live/${REDIS_ADMIN_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${REDIS_ADMIN_DOMAIN}"

if [[ -f "${REDIS_ENV}" ]]; then
  set -a && source "${REDIS_ENV}" && set +a
  REDIS_ADMIN_BACKEND_PORT="${REDISINSIGHT_PORT:-${REDIS_ADMIN_BACKEND_PORT}}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_redis_admin_basic_auth_file

SITE="/etc/nginx/sites-available/${REDIS_ADMIN_DOMAIN}"
export REDIS_ADMIN_DOMAIN REDIS_ADMIN_BACKEND_HOST REDIS_ADMIN_BACKEND_PORT \
  CERTBOT_WEBROOT REDIS_ADMIN_HTASSWD_FILE
envsubst '${REDIS_ADMIN_DOMAIN} ${REDIS_ADMIN_BACKEND_HOST} ${REDIS_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${REDIS_ADMIN_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/redis.wise-eat.com.https.conf.template" > "${SITE}"

ln -sf "${SITE}" "/etc/nginx/sites-enabled/${REDIS_ADMIN_DOMAIN}"
nginx_test_and_reload
log "nginx HTTPS Redis Admin activé — https://${REDIS_ADMIN_DOMAIN}"
