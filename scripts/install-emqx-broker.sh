#!/usr/bin/env bash
# Reverse-proxy nginx → EMQX (MQTTS :8883 stream + WSS :8884) + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

CALLER_EMQX_BROKER_DOMAIN="${EMQX_BROKER_DOMAIN-__CALLER_UNSET__}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
fi

EMQX_BROKER_DOMAIN="${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}"
EMQX_BACKEND_HOST="${EMQX_BACKEND_HOST:-127.0.0.1}"
EMQX_MQTT_PORT="${EMQX_MQTT_PORT:-1883}"
EMQX_WS_PORT="${EMQX_WS_PORT:-8083}"
EMQX_MQTTS_PORT="${EMQX_MQTTS_PORT:-8883}"
EMQX_WSS_PORT="${EMQX_WSS_PORT:-8884}"

if [[ "${CALLER_EMQX_BROKER_DOMAIN}" != "__CALLER_UNSET__" ]]; then
  EMQX_BROKER_DOMAIN="${CALLER_EMQX_BROKER_DOMAIN}"
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

ensure_nginx_stream_include

SITE="/etc/nginx/sites-available/${EMQX_BROKER_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${EMQX_BROKER_DOMAIN}"
STREAM_SITE="/etc/nginx/stream.d/${EMQX_BROKER_DOMAIN}.conf"

render_emqx_http_site() {
  local template="$1"
  export EMQX_BROKER_DOMAIN EMQX_MQTTS_PORT EMQX_WSS_PORT CERTBOT_WEBROOT
  envsubst '${EMQX_BROKER_DOMAIN} ${EMQX_MQTTS_PORT} ${EMQX_WSS_PORT} ${CERTBOT_WEBROOT}' \
    < "${template}" > "${SITE}"
}

render_emqx_stream_site() {
  local template="$1"
  export EMQX_BROKER_DOMAIN EMQX_BACKEND_HOST EMQX_MQTT_PORT EMQX_MQTTS_PORT
  envsubst '${EMQX_BROKER_DOMAIN} ${EMQX_BACKEND_HOST} ${EMQX_MQTT_PORT} ${EMQX_MQTTS_PORT}' \
    < "${template}" > "${STREAM_SITE}"
}

if [[ -f "/etc/letsencrypt/live/${EMQX_BROKER_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  export EMQX_BACKEND_HOST EMQX_WS_PORT EMQX_WSS_PORT CERTBOT_WEBROOT
  envsubst '${EMQX_BROKER_DOMAIN} ${EMQX_BACKEND_HOST} ${EMQX_WS_PORT} ${EMQX_WSS_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/broker.wise-eat.com.https.conf.template" > "${SITE}"
  render_emqx_stream_site "${NGINX_CONF_SRC}/broker.wise-eat.com.stream.conf.template"
  log "Config nginx HTTPS/WSS + stream MQTTS (${EMQX_BROKER_DOMAIN})"
else
  render_emqx_http_site "${NGINX_CONF_SRC}/broker.wise-eat.com.http.conf.template"
  rm -f "${STREAM_SITE}"
  log "Config nginx HTTP ACME (${EMQX_BROKER_DOMAIN}) — MQTTS/WSS après certbot"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx_test_and_reload

if command -v ufw >/dev/null 2>&1; then
  ensure_ufw_ipv6_enabled
  ufw_allow_tcp_port "${EMQX_MQTTS_PORT}" "nginx MQTTS ${EMQX_BROKER_DOMAIN}"
  ufw_allow_tcp_port "${EMQX_WSS_PORT}" "nginx WSS ${EMQX_BROKER_DOMAIN}"
  ufw reload
  log "UFW : ports ${EMQX_MQTTS_PORT}/${EMQX_WSS_PORT} ouverts (v4 + v6 si IPV6=yes)"
else
  warn "ufw absent — ouvrir manuellement ${EMQX_MQTTS_PORT}/tcp et ${EMQX_WSS_PORT}/tcp (v4 + v6)"
fi

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${EMQX_BROKER_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${EMQX_BROKER_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${EMQX_BROKER_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-emqx-broker-ssl.sh"
fi

log "EMQX public : mqtts://${EMQX_BROKER_DOMAIN}:${EMQX_MQTTS_PORT}"
log "EMQX WSS    : wss://${EMQX_BROKER_DOMAIN}:${EMQX_WSS_PORT}/mqtt"
