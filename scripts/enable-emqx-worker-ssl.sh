#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
EMQX_WORKER_DOMAIN="${EMQX_WORKER_DOMAIN:-worker.wise-eat.com}"
EMQX_DASHBOARD_BACKEND_HOST="${EMQX_DASHBOARD_BACKEND_HOST:-127.0.0.1}"
EMQX_DASHBOARD_BACKEND_PORT="${EMQX_DASHBOARD_BACKEND_PORT:-18083}"

[[ -f "/etc/letsencrypt/live/${EMQX_WORKER_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${EMQX_WORKER_DOMAIN}"

if [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
  EMQX_DASHBOARD_BACKEND_PORT="${EMQX_DASHBOARD_PORT:-${EMQX_DASHBOARD_BACKEND_PORT}}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_emqx_worker_basic_auth_file

SITE="/etc/nginx/sites-available/${EMQX_WORKER_DOMAIN}"
export EMQX_WORKER_DOMAIN EMQX_DASHBOARD_BACKEND_HOST EMQX_DASHBOARD_BACKEND_PORT \
  CERTBOT_WEBROOT EMQX_WORKER_HTASSWD_FILE
envsubst '${EMQX_WORKER_DOMAIN} ${EMQX_DASHBOARD_BACKEND_HOST} ${EMQX_DASHBOARD_BACKEND_PORT} ${CERTBOT_WEBROOT} ${EMQX_WORKER_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/worker.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS EMQX Dashboard activé — https://${EMQX_WORKER_DOMAIN}"
