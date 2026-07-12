#!/usr/bin/env bash
# Reverse-proxy nginx → Neo4j Browser (db-graph.wise-eat.com) + Bolt TLS :7688 + Certbot.
# Note : DbGate ne propose pas de plugin Neo4j — on expose le Browser natif.
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
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ ! -f "${NEO4J_ENV}" ]]; then
  warn "Neo4j absent — installation"
  bash "${SCRIPT_DIR}/install-neo4j.sh"
fi

if [[ -f "${NEO4J_ENV}" ]]; then
  source_dotenv "${NEO4J_ENV}"
  NEO4J_ADMIN_BACKEND_PORT="${NEO4J_HTTP_PORT:-${NEO4J_ADMIN_BACKEND_PORT}}"
  NEO4J_BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
  NEO4J_BOLT_TLS_PORT="${NEO4J_BOLT_TLS_PORT:-7688}"
fi

# Advertised public pour le Browser (HTTP :443, Bolt TLS :7688)
persist_neo4j_admin_advertised() {
  local http_adv="${NEO4J_ADMIN_DOMAIN}:443"
  local bolt_adv="${NEO4J_ADMIN_DOMAIN}:${NEO4J_BOLT_TLS_PORT}"
  for pair in "NEO4J_HTTP_ADVERTISED=${http_adv}" "NEO4J_BOLT_ADVERTISED=${bolt_adv}"; do
    local key="${pair%%=*}" val="${pair#*=}"
    if grep -q "^${key}=" "${NEO4J_ENV}" 2>/dev/null; then
      local tmp
      tmp="$(mktemp)"
      sed "s|^${key}=.*|${key}=${val}|" "${NEO4J_ENV}" > "${tmp}"
      cat "${tmp}" > "${NEO4J_ENV}"
      rm -f "${tmp}"
    else
      echo "${key}=${val}" >> "${NEO4J_ENV}"
    fi
  done
  export NEO4J_HTTP_ADVERTISED="${http_adv}"
  export NEO4J_BOLT_ADVERTISED="${bolt_adv}"
}

# Générer mot de passe basic auth si manquant
if [[ -z "${NEO4J_ADMIN_BASIC_AUTH_PASSWORD:-}" ]]; then
  existing="$(read_env_var_from_file "${NEO4J_ENV}" NEO4J_ADMIN_BASIC_AUTH_PASSWORD || true)"
  if [[ -z "${existing}" ]]; then
    NEO4J_ADMIN_BASIC_AUTH_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    if grep -q '^NEO4J_ADMIN_BASIC_AUTH_PASSWORD=' "${NEO4J_ENV}" 2>/dev/null; then
      tmp="$(mktemp)"
      sed "s|^NEO4J_ADMIN_BASIC_AUTH_PASSWORD=.*|NEO4J_ADMIN_BASIC_AUTH_PASSWORD=${NEO4J_ADMIN_BASIC_AUTH_PASSWORD}|" \
        "${NEO4J_ENV}" > "${tmp}"
      cat "${tmp}" > "${NEO4J_ENV}"
      rm -f "${tmp}"
    else
      {
        echo ""
        echo "NEO4J_ADMIN_DOMAIN=${NEO4J_ADMIN_DOMAIN}"
        echo "NEO4J_ADMIN_BASIC_AUTH_USER=${NEO4J_ADMIN_BASIC_AUTH_USER:-neo4j-admin}"
        echo "NEO4J_ADMIN_BASIC_AUTH_PASSWORD=${NEO4J_ADMIN_BASIC_AUTH_PASSWORD}"
        echo "NEO4J_BOLT_TLS_PORT=${NEO4J_BOLT_TLS_PORT}"
      } >> "${NEO4J_ENV}"
    fi
    log "Mot de passe Neo4j Admin généré → ${NEO4J_ENV}"
  else
    NEO4J_ADMIN_BASIC_AUTH_PASSWORD="${existing}"
  fi
fi

persist_neo4j_admin_advertised

ensure_docker
ensure_wise_eat_infra_network
sync_component neo4j
cd "${NEO4J_DIR}"

# Retirer l’ancien DbGate (pas de plugin Neo4j)
docker rm -f wise-eat-neo4j-dbgate 2>/dev/null || true

source_dotenv .env.neo4j
docker compose --env-file .env.neo4j up -d --force-recreate neo4j

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_neo4j_admin_basic_auth_file
ensure_nginx_stream_include

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${NEO4J_ADMIN_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${NEO4J_ADMIN_DOMAIN}"
STREAM_SITE="/etc/nginx/stream.d/${NEO4J_ADMIN_DOMAIN}.conf"

render_neo4j_admin_site() {
  local template="$1"
  export NEO4J_ADMIN_DOMAIN NEO4J_ADMIN_BACKEND_HOST NEO4J_ADMIN_BACKEND_PORT \
    CERTBOT_WEBROOT NEO4J_ADMIN_HTASSWD_FILE
  envsubst '${NEO4J_ADMIN_DOMAIN} ${NEO4J_ADMIN_BACKEND_HOST} ${NEO4J_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${NEO4J_ADMIN_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

render_neo4j_bolt_stream() {
  export NEO4J_ADMIN_DOMAIN NEO4J_ADMIN_BACKEND_HOST NEO4J_BOLT_PORT NEO4J_BOLT_TLS_PORT
  envsubst '${NEO4J_ADMIN_DOMAIN} ${NEO4J_ADMIN_BACKEND_HOST} ${NEO4J_BOLT_PORT} ${NEO4J_BOLT_TLS_PORT}' \
    < "${NGINX_CONF_SRC}/db-graph.wise-eat.com.stream.conf.template" > "${STREAM_SITE}"
}

if [[ -f "/etc/letsencrypt/live/${NEO4J_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_neo4j_admin_site "${NGINX_CONF_SRC}/db-graph.wise-eat.com.https.conf.template"
  render_neo4j_bolt_stream
  log "Config nginx HTTPS Neo4j Browser + stream Bolt TLS :${NEO4J_BOLT_TLS_PORT}"
else
  render_neo4j_admin_site "${NGINX_CONF_SRC}/db-graph.wise-eat.com.http.conf.template"
  rm -f "${STREAM_SITE}"
  log "Config nginx HTTP Neo4j Browser → ${NEO4J_ADMIN_BACKEND_HOST}:${NEO4J_ADMIN_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx_test_and_reload

if command -v ufw >/dev/null 2>&1; then
  ensure_ufw_ipv6_enabled 2>/dev/null || true
  ufw_allow_tcp_port "${NEO4J_BOLT_TLS_PORT}" "nginx Bolt TLS ${NEO4J_ADMIN_DOMAIN}" 2>/dev/null \
    || ufw allow "${NEO4J_BOLT_TLS_PORT}/tcp" comment "nginx Bolt TLS ${NEO4J_ADMIN_DOMAIN}" 2>/dev/null || true
  ufw reload 2>/dev/null || true
fi

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

log "Neo4j Browser : https://${NEO4J_ADMIN_DOMAIN}"
log "  Basic auth nginx : ${NEO4J_ADMIN_BASIC_AUTH_USER:-neo4j-admin}"
log "    Mot de passe : NEO4J_ADMIN_BASIC_AUTH_PASSWORD dans ${NEO4J_ENV}"
log "  Connexion Bolt dans Browser : bolt+s://${NEO4J_ADMIN_DOMAIN}:${NEO4J_BOLT_TLS_PORT}"
log "  Auth Neo4j : ${NEO4J_USER:-neo4j} / NEO4J_PASSWORD"
log "  Cloudflare : ${NEO4J_ADMIN_DOMAIN} proxy OK (443) ; port ${NEO4J_BOLT_TLS_PORT} en DNS only"
