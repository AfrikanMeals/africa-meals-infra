#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
HAPROXY_PROXY_DOMAIN="${HAPROXY_PROXY_DOMAIN:-proxy.wise-eat.com}"
HAPROXY_STATS_HOST="${HAPROXY_STATS_HOST:-127.0.0.1}"
HAPROXY_STATS_PORT="${HAPROXY_STATS_PORT:-8404}"

[[ -f "/etc/letsencrypt/live/${HAPROXY_PROXY_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${HAPROXY_PROXY_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_haproxy_proxy_basic_auth_file

SITE="/etc/nginx/sites-available/${HAPROXY_PROXY_DOMAIN}"
export HAPROXY_PROXY_DOMAIN HAPROXY_STATS_HOST HAPROXY_STATS_PORT \
  CERTBOT_WEBROOT HAPROXY_PROXY_HTASSWD_FILE
envsubst '${HAPROXY_PROXY_DOMAIN} ${HAPROXY_STATS_HOST} ${HAPROXY_STATS_PORT} ${CERTBOT_WEBROOT} ${HAPROXY_PROXY_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/proxy.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS HAProxy UI — https://${HAPROXY_PROXY_DOMAIN}/stats"
