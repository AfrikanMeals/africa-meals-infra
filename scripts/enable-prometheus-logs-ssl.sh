#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
PROMETHEUS_LOGS_DOMAIN="${PROMETHEUS_LOGS_DOMAIN:-logs.wise-eat.com}"
PROMETHEUS_BACKEND_HOST="${PROMETHEUS_BACKEND_HOST:-127.0.0.1}"
PROMETHEUS_BACKEND_PORT="${PROMETHEUS_BACKEND_PORT:-9090}"

[[ -f "/etc/letsencrypt/live/${PROMETHEUS_LOGS_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${PROMETHEUS_LOGS_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_prometheus_basic_auth_file

SITE="/etc/nginx/sites-available/${PROMETHEUS_LOGS_DOMAIN}"
export PROMETHEUS_LOGS_DOMAIN PROMETHEUS_BACKEND_HOST PROMETHEUS_BACKEND_PORT \
  CERTBOT_WEBROOT PROMETHEUS_HTASSWD_FILE
envsubst '${PROMETHEUS_LOGS_DOMAIN} ${PROMETHEUS_BACKEND_HOST} ${PROMETHEUS_BACKEND_PORT} ${CERTBOT_WEBROOT} ${PROMETHEUS_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/logs.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS Prometheus activé — https://${PROMETHEUS_LOGS_DOMAIN}"
