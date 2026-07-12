#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
NEO4J_ADMIN_DOMAIN="${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}"
NEO4J_ADMIN_BACKEND_HOST="${NEO4J_ADMIN_BACKEND_HOST:-127.0.0.1}"
NEO4J_ADMIN_BACKEND_PORT="${NEO4J_ADMIN_BACKEND_PORT:-8082}"

[[ -f "/etc/letsencrypt/live/${NEO4J_ADMIN_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${NEO4J_ADMIN_DOMAIN}"

if [[ -f "${NEO4J_ENV}" ]]; then
  source_dotenv "${NEO4J_ENV}"
  NEO4J_ADMIN_BACKEND_PORT="${NEO4J_DBGATE_PORT:-${NEO4J_ADMIN_BACKEND_PORT}}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_neo4j_admin_basic_auth_file

SITE="/etc/nginx/sites-available/${NEO4J_ADMIN_DOMAIN}"
export NEO4J_ADMIN_DOMAIN NEO4J_ADMIN_BACKEND_HOST NEO4J_ADMIN_BACKEND_PORT \
  CERTBOT_WEBROOT NEO4J_ADMIN_HTASSWD_FILE
envsubst '${NEO4J_ADMIN_DOMAIN} ${NEO4J_ADMIN_BACKEND_HOST} ${NEO4J_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${NEO4J_ADMIN_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/db-graph.wise-eat.com.https.conf.template" > "${SITE}"

ln -sf "${SITE}" "/etc/nginx/sites-enabled/${NEO4J_ADMIN_DOMAIN}"
nginx_test_and_reload
log "nginx HTTPS Neo4j Admin activé — https://${NEO4J_ADMIN_DOMAIN}"
