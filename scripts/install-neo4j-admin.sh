#!/usr/bin/env bash
# Reverse-proxy nginx → DbGate Neo4j (db-graph.wise-eat.com) + basic auth + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

NEO4J_ADMIN_DOMAIN="${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}"
NEO4J_ADMIN_BACKEND_HOST="${NEO4J_ADMIN_BACKEND_HOST:-127.0.0.1}"
NEO4J_ADMIN_BACKEND_PORT="${NEO4J_ADMIN_BACKEND_PORT:-8082}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ ! -f "${NEO4J_ENV}" ]]; then
  warn "Neo4j absent — installation"
  bash "${SCRIPT_DIR}/install-neo4j.sh"
fi

if [[ -f "${NEO4J_ENV}" ]]; then
  source_dotenv "${NEO4J_ENV}"
  NEO4J_ADMIN_BACKEND_PORT="${NEO4J_DBGATE_PORT:-${NEO4J_ADMIN_BACKEND_PORT}}"
fi

# Générer mot de passe basic auth si manquant
if [[ -z "${NEO4J_ADMIN_BASIC_AUTH_PASSWORD:-}" ]]; then
  existing="$(read_env_var_from_file "${NEO4J_ENV}" NEO4J_ADMIN_BASIC_AUTH_PASSWORD || true)"
  if [[ -z "${existing}" ]]; then
    NEO4J_ADMIN_BASIC_AUTH_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    if grep -q '^NEO4J_ADMIN_BASIC_AUTH_PASSWORD=' "${NEO4J_ENV}" 2>/dev/null; then
      sed -i "s|^NEO4J_ADMIN_BASIC_AUTH_PASSWORD=.*|NEO4J_ADMIN_BASIC_AUTH_PASSWORD=${NEO4J_ADMIN_BASIC_AUTH_PASSWORD}|" "${NEO4J_ENV}"
    else
      {
        echo ""
        echo "NEO4J_ADMIN_DOMAIN=${NEO4J_ADMIN_DOMAIN}"
        echo "NEO4J_ADMIN_BASIC_AUTH_USER=${NEO4J_ADMIN_BASIC_AUTH_USER:-neo4j-admin}"
        echo "NEO4J_ADMIN_BASIC_AUTH_PASSWORD=${NEO4J_ADMIN_BASIC_AUTH_PASSWORD}"
      } >> "${NEO4J_ENV}"
    fi
    log "Mot de passe Neo4j Admin généré → ${NEO4J_ENV}"
  else
    NEO4J_ADMIN_BASIC_AUTH_PASSWORD="${existing}"
  fi
fi

# S’assurer que DbGate tourne
ensure_docker
ensure_wise_eat_infra_network
sync_component neo4j
cd "${NEO4J_DIR}"
mkdir -p "${NEO4J_DBGATE_DATA:-./data-dbgate}"
docker compose --env-file .env.neo4j up -d neo4j dbgate

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_neo4j_admin_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${NEO4J_ADMIN_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${NEO4J_ADMIN_DOMAIN}"

render_neo4j_admin_site() {
  local template="$1"
  export NEO4J_ADMIN_DOMAIN NEO4J_ADMIN_BACKEND_HOST NEO4J_ADMIN_BACKEND_PORT \
    CERTBOT_WEBROOT NEO4J_ADMIN_HTASSWD_FILE
  envsubst '${NEO4J_ADMIN_DOMAIN} ${NEO4J_ADMIN_BACKEND_HOST} ${NEO4J_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${NEO4J_ADMIN_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${NEO4J_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_neo4j_admin_site "${NGINX_CONF_SRC}/db-graph.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS Neo4j Admin (${NEO4J_ADMIN_DOMAIN})"
else
  render_neo4j_admin_site "${NGINX_CONF_SRC}/db-graph.wise-eat.com.http.conf.template"
  log "Config nginx HTTP Neo4j Admin → ${NEO4J_ADMIN_BACKEND_HOST}:${NEO4J_ADMIN_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx_test_and_reload

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${NEO4J_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${NEO4J_ADMIN_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${NEO4J_ADMIN_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-neo4j-admin-ssl.sh"
fi

log "Neo4j Admin public : https://${NEO4J_ADMIN_DOMAIN}"
log "  Basic auth nginx : ${NEO4J_ADMIN_BASIC_AUTH_USER:-neo4j-admin}"
log "    Mot de passe : NEO4J_ADMIN_BASIC_AUTH_PASSWORD dans ${NEO4J_ENV}"
log "  Bolt reste privé (127.0.0.1:7687) — DbGate se connecte en interne"
