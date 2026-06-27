#!/usr/bin/env bash
# Bascule nginx hôte vers le NodePort k3s (30800) au lieu de PM2 (:8000).
#
# Usage :
#   sudo ./patch-nginx-ws-backend.sh
#   sudo WS_BACKEND_PORT=30800 ./patch-nginx-ws-backend.sh
#
# Rollback PM2 :
#   sudo WS_BACKEND_PORT=8000 ./patch-nginx-ws-backend.sh
set -euo pipefail

WS_BACKEND_HOST="${WS_BACKEND_HOST:-127.0.0.1}"
WS_BACKEND_PORT="${WS_BACKEND_PORT:-30800}"
WISE_EAT_DOMAIN="${WISE_EAT_DOMAIN:-wise-eat.cloud}"

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NGINX_CONF_SRC="${INFRA_ROOT}/nginx"
SITE="/etc/nginx/sites-available/${WISE_EAT_DOMAIN}.conf"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

if [[ ! -d "${NGINX_CONF_SRC}" ]]; then
  echo "Templates nginx introuvables : ${NGINX_CONF_SRC}" >&2
  exit 1
fi

export WISE_EAT_DOMAIN WS_BACKEND_HOST WS_BACKEND_PORT CERTBOT_WEBROOT="${CERTBOT_WEBROOT:-/var/www/certbot}"

if [[ -f "/etc/letsencrypt/live/${WISE_EAT_DOMAIN}/fullchain.pem" ]]; then
  envsubst '${WISE_EAT_DOMAIN} ${WS_BACKEND_HOST} ${WS_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/wise-eat.cloud.https.conf.template" > "${SITE}"
  echo "nginx HTTPS → ${WS_BACKEND_HOST}:${WS_BACKEND_PORT}"
else
  envsubst '${WISE_EAT_DOMAIN} ${WS_BACKEND_HOST} ${WS_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/wise-eat.cloud.http.conf.template" > "${SITE}"
  echo "nginx HTTP → ${WS_BACKEND_HOST}:${WS_BACKEND_PORT}"
fi

nginx -t
systemctl reload nginx

echo "nginx rechargé — ${WISE_EAT_DOMAIN} → WS ${WS_BACKEND_HOST}:${WS_BACKEND_PORT}"
