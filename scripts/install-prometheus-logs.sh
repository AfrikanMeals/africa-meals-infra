#!/usr/bin/env bash
# Reverse-proxy nginx → Prometheus (logs.wise-eat.com) + basic auth + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

PROMETHEUS_LOGS_DOMAIN="${PROMETHEUS_LOGS_DOMAIN:-logs.wise-eat.com}"
PROMETHEUS_BACKEND_HOST="${PROMETHEUS_BACKEND_HOST:-127.0.0.1}"
PROMETHEUS_BACKEND_PORT="${PROMETHEUS_BACKEND_PORT:-9090}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${MON_DIR}/.env.monitoring" ]]; then
  sanitize_monitoring_env_file "${MON_DIR}/.env.monitoring"
  source_dotenv "${MON_DIR}/.env.monitoring"
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_prometheus_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${PROMETHEUS_LOGS_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${PROMETHEUS_LOGS_DOMAIN}"

render_prometheus_site() {
  local template="$1"
  export PROMETHEUS_LOGS_DOMAIN PROMETHEUS_BACKEND_HOST PROMETHEUS_BACKEND_PORT \
    CERTBOT_WEBROOT PROMETHEUS_HTASSWD_FILE
  envsubst '${PROMETHEUS_LOGS_DOMAIN} ${PROMETHEUS_BACKEND_HOST} ${PROMETHEUS_BACKEND_PORT} ${CERTBOT_WEBROOT} ${PROMETHEUS_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${PROMETHEUS_LOGS_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_prometheus_site "${NGINX_CONF_SRC}/logs.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS Prometheus (${PROMETHEUS_LOGS_DOMAIN})"
else
  render_prometheus_site "${NGINX_CONF_SRC}/logs.wise-eat.com.http.conf.template"
  log "Config nginx HTTP Prometheus → ${PROMETHEUS_BACKEND_HOST}:${PROMETHEUS_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${PROMETHEUS_LOGS_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${PROMETHEUS_LOGS_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${PROMETHEUS_LOGS_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-prometheus-logs-ssl.sh"
fi

log "Prometheus public : https://${PROMETHEUS_LOGS_DOMAIN} (basic auth nginx)"
log "Vérifier monitoring : PROMETHEUS_EXTERNAL_URL=https://${PROMETHEUS_LOGS_DOMAIN}/"
