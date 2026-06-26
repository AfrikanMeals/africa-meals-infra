#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
OLLAMA_GATEWAY_DOMAIN="${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}"
OLLAMA_BACKEND_HOST="${OLLAMA_BACKEND_HOST:-127.0.0.1}"
OLLAMA_BACKEND_PORT="${OLLAMA_BACKEND_PORT:-11434}"

[[ -f "/etc/letsencrypt/live/${OLLAMA_GATEWAY_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${OLLAMA_GATEWAY_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

if [[ -f "${OLLAMA_DIR}/.env.ollama" ]]; then
  set -a && source "${OLLAMA_DIR}/.env.ollama" && set +a
fi

ensure_letsencrypt_nginx_tls_files
ensure_ollama_gateway_basic_auth_file

SITE="/etc/nginx/sites-available/${OLLAMA_GATEWAY_DOMAIN}"
export OLLAMA_GATEWAY_DOMAIN OLLAMA_BACKEND_HOST OLLAMA_BACKEND_PORT \
  CERTBOT_WEBROOT OLLAMA_GATEWAY_HTASSWD_FILE
envsubst '${OLLAMA_GATEWAY_DOMAIN} ${OLLAMA_BACKEND_HOST} ${OLLAMA_BACKEND_PORT} ${CERTBOT_WEBROOT} ${OLLAMA_GATEWAY_HTASSWD_FILE}' \
  < "${NGINX_CONF_SRC}/ai.wise-eat.com.https.conf.template" > "${SITE}"

nginx -t
systemctl reload nginx
log "nginx HTTPS Ollama activé — https://${OLLAMA_GATEWAY_DOMAIN}"
