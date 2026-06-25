#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

if [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
fi

EMQX_BROKER_DOMAIN="${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}"
EMQX_BACKEND_HOST="${EMQX_BACKEND_HOST:-127.0.0.1}"
EMQX_MQTT_PORT="${EMQX_MQTT_PORT:-1883}"
EMQX_WS_PORT="${EMQX_WS_PORT:-8083}"
EMQX_MQTTS_PORT="${EMQX_MQTTS_PORT:-8883}"
EMQX_WSS_PORT="${EMQX_WSS_PORT:-8884}"

[[ -f "/etc/letsencrypt/live/${EMQX_BROKER_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent pour ${EMQX_BROKER_DOMAIN}"

command -v nginx >/dev/null 2>&1 || die "nginx non installé"

ensure_letsencrypt_nginx_tls_files
ensure_nginx_stream_include

SITE="/etc/nginx/sites-available/${EMQX_BROKER_DOMAIN}"
STREAM_SITE="/etc/nginx/stream.d/${EMQX_BROKER_DOMAIN}.conf"

export EMQX_BROKER_DOMAIN EMQX_BACKEND_HOST EMQX_WS_PORT EMQX_WSS_PORT CERTBOT_WEBROOT
envsubst '${EMQX_BROKER_DOMAIN} ${EMQX_BACKEND_HOST} ${EMQX_WS_PORT} ${EMQX_WSS_PORT} ${CERTBOT_WEBROOT}' \
  < "${NGINX_CONF_SRC}/broker.wise-eat.com.https.conf.template" > "${SITE}"

export EMQX_MQTT_PORT EMQX_MQTTS_PORT
envsubst '${EMQX_BROKER_DOMAIN} ${EMQX_BACKEND_HOST} ${EMQX_MQTT_PORT} ${EMQX_MQTTS_PORT}' \
  < "${NGINX_CONF_SRC}/broker.wise-eat.com.stream.conf.template" > "${STREAM_SITE}"

ln -sf "${SITE}" "/etc/nginx/sites-enabled/${EMQX_BROKER_DOMAIN}"

nginx -t
systemctl reload nginx
log "nginx MQTTS/WSS activé — mqtts://${EMQX_BROKER_DOMAIN}:${EMQX_MQTTS_PORT}"
