#!/usr/bin/env bash
# Reverse-proxy nginx → Ollama (ai.wise-eat.com) + basic auth + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

OLLAMA_GATEWAY_DOMAIN="${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}"
OLLAMA_BACKEND_HOST="${OLLAMA_BACKEND_HOST:-127.0.0.1}"
OLLAMA_BACKEND_PORT="${OLLAMA_BACKEND_PORT:-11434}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${OLLAMA_DIR}/.env.ollama" ]]; then
  set -a && source "${OLLAMA_DIR}/.env.ollama" && set +a
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_ollama_gateway_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${OLLAMA_GATEWAY_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${OLLAMA_GATEWAY_DOMAIN}"

render_ollama_site() {
  local template="$1"
  export OLLAMA_GATEWAY_DOMAIN OLLAMA_BACKEND_HOST OLLAMA_BACKEND_PORT \
    CERTBOT_WEBROOT OLLAMA_GATEWAY_HTASSWD_FILE
  envsubst '${OLLAMA_GATEWAY_DOMAIN} ${OLLAMA_BACKEND_HOST} ${OLLAMA_BACKEND_PORT} ${CERTBOT_WEBROOT} ${OLLAMA_GATEWAY_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${OLLAMA_GATEWAY_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_ollama_site "${NGINX_CONF_SRC}/ai.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS Ollama (${OLLAMA_GATEWAY_DOMAIN})"
else
  render_ollama_site "${NGINX_CONF_SRC}/ai.wise-eat.com.http.conf.template"
  log "Config nginx HTTP Ollama → ${OLLAMA_BACKEND_HOST}:${OLLAMA_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${OLLAMA_GATEWAY_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${OLLAMA_GATEWAY_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${OLLAMA_GATEWAY_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-ollama-gateway-ssl.sh"
fi

log "Ollama public : https://${OLLAMA_GATEWAY_DOMAIN} (basic auth nginx, dual-stack IPv4/IPv6)"
log "DNS requis : A + AAAA ${OLLAMA_GATEWAY_DOMAIN} → VPS (proxy Cloudflare OK pour :443)"
