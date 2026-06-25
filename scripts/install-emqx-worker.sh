#!/usr/bin/env bash
# Reverse-proxy nginx → EMQX Dashboard (worker.wise-eat.com) + basic auth + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

EMQX_WORKER_DOMAIN="${EMQX_WORKER_DOMAIN:-worker.wise-eat.com}"
EMQX_DASHBOARD_BACKEND_HOST="${EMQX_DASHBOARD_BACKEND_HOST:-127.0.0.1}"
EMQX_DASHBOARD_BACKEND_PORT="${EMQX_DASHBOARD_BACKEND_PORT:-18083}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
  EMQX_DASHBOARD_BACKEND_PORT="${EMQX_DASHBOARD_PORT:-${EMQX_DASHBOARD_BACKEND_PORT}}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_emqx_worker_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${EMQX_WORKER_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${EMQX_WORKER_DOMAIN}"

render_emqx_worker_site() {
  local template="$1"
  export EMQX_WORKER_DOMAIN EMQX_DASHBOARD_BACKEND_HOST EMQX_DASHBOARD_BACKEND_PORT \
    CERTBOT_WEBROOT EMQX_WORKER_HTASSWD_FILE
  envsubst '${EMQX_WORKER_DOMAIN} ${EMQX_DASHBOARD_BACKEND_HOST} ${EMQX_DASHBOARD_BACKEND_PORT} ${CERTBOT_WEBROOT} ${EMQX_WORKER_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${EMQX_WORKER_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_emqx_worker_site "${NGINX_CONF_SRC}/worker.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS EMQX Dashboard (${EMQX_WORKER_DOMAIN})"
else
  render_emqx_worker_site "${NGINX_CONF_SRC}/worker.wise-eat.com.http.conf.template"
  log "Config nginx HTTP EMQX Dashboard → ${EMQX_DASHBOARD_BACKEND_HOST}:${EMQX_DASHBOARD_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${EMQX_WORKER_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${EMQX_WORKER_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${EMQX_WORKER_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-emqx-worker-ssl.sh"
fi

log "EMQX Dashboard public : https://${EMQX_WORKER_DOMAIN}"
log "  Couche 1 : basic auth nginx (${EMQX_WORKER_BASIC_AUTH_USER:-emqx-worker})"
log "    Mot de passe : EMQX_WORKER_BASIC_AUTH_PASSWORD dans ${EMQX_ENV}"
log "  Couche 2 : EMQX dashboard (${EMQX_DASHBOARD_USERNAME:-admin} / EMQX_DASHBOARD_PASSWORD)"
