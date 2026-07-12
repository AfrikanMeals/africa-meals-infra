#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
NEO4J_ADMIN_DOMAIN="${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}"
NEO4J_ADMIN_BACKEND_HOST="${NEO4J_ADMIN_BACKEND_HOST:-127.0.0.1}"
NEO4J_ADMIN_BACKEND_PORT="${NEO4J_ADMIN_BACKEND_PORT:-7474}"
NEO4J_BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
NEO4J_BOLT_TLS_PORT="${NEO4J_BOLT_TLS_PORT:-7688}"

[[ -f "/etc/letsencrypt/live/${NEO4J_ADMIN_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${NEO4J_ADMIN_DOMAIN}"

if [[ -f "${NEO4J_ENV}" ]]; then
  source_dotenv "${NEO4J_ENV}"
  NEO4J_ADMIN_BACKEND_PORT="${NEO4J_HTTP_PORT:-${NEO4J_ADMIN_BACKEND_PORT}}"
  NEO4J_BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
  NEO4J_BOLT_TLS_PORT="${NEO4J_BOLT_TLS_PORT:-7688}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_neo4j_admin_basic_auth_file
ensure_nginx_stream_include

SITE="/etc/nginx/sites-available/${NEO4J_ADMIN_DOMAIN}"
STREAM_SITE="/etc/nginx/stream.d/${NEO4J_ADMIN_DOMAIN}.conf"

export NEO4J_ADMIN_DOMAIN NEO4J_ADMIN_BACKEND_HOST NEO4J_ADMIN_BACKEND_PORT \
  CERTBOT_WEBROOT NEO4J_ADMIN_HTASSWD_FILE
envsubst '${NEO4J_ADMIN_DOMAIN} ${NEO4J_ADMIN_BACKEND_HOST} ${NEO4J_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${NEO4J_ADMIN_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/db-graph.wise-eat.com.https.conf.template" > "${SITE}"

export NEO4J_BOLT_PORT NEO4J_BOLT_TLS_PORT
envsubst '${NEO4J_ADMIN_DOMAIN} ${NEO4J_ADMIN_BACKEND_HOST} ${NEO4J_BOLT_PORT} ${NEO4J_BOLT_TLS_PORT}' \
  < "${NGINX_CONF_SRC}/db-graph.wise-eat.com.stream.conf.template" > "${STREAM_SITE}"

ln -sf "${SITE}" "/etc/nginx/sites-enabled/${NEO4J_ADMIN_DOMAIN}"
nginx_test_and_reload

if command -v ufw >/dev/null 2>&1; then
  ufw_allow_tcp_port "${NEO4J_BOLT_TLS_PORT}" "nginx Bolt TLS ${NEO4J_ADMIN_DOMAIN}" 2>/dev/null \
    || ufw allow "${NEO4J_BOLT_TLS_PORT}/tcp" comment "nginx Bolt TLS ${NEO4J_ADMIN_DOMAIN}" 2>/dev/null || true
  ufw reload 2>/dev/null || true
fi

log "nginx HTTPS Neo4j Browser + Bolt TLS :${NEO4J_BOLT_TLS_PORT} — https://${NEO4J_ADMIN_DOMAIN}"
log "  Browser connect URI : bolt+s://${NEO4J_ADMIN_DOMAIN}:${NEO4J_BOLT_TLS_PORT}"
