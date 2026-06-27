#!/usr/bin/env bash
# nginx k8s.wise-eat.com → Headlamp NodePort 30850 (+ basic auth).
# Usage :
#   sudo K8S_DASHBOARD_BASIC_AUTH_PASSWORD='…' ./install-k8s-nginx.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

K8S_DASHBOARD_DOMAIN="${K8S_DASHBOARD_DOMAIN:-k8s.wise-eat.com}"
K8S_DASHBOARD_BACKEND_HOST="${K8S_DASHBOARD_BACKEND_HOST:-127.0.0.1}"
K8S_DASHBOARD_BACKEND_PORT="${K8S_DASHBOARD_BACKEND_PORT:-30850}"

ensure_k8s_dashboard_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${K8S_DASHBOARD_DOMAIN}.conf"
ENABLED="/etc/nginx/sites-enabled/${K8S_DASHBOARD_DOMAIN}.conf"

export K8S_DASHBOARD_DOMAIN K8S_DASHBOARD_BACKEND_HOST K8S_DASHBOARD_BACKEND_PORT
export K8S_DASHBOARD_HTASSWD_FILE CERTBOT_WEBROOT

if [[ -f "/etc/letsencrypt/live/${K8S_DASHBOARD_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  envsubst '${K8S_DASHBOARD_DOMAIN} ${K8S_DASHBOARD_BACKEND_HOST} ${K8S_DASHBOARD_BACKEND_PORT} ${K8S_DASHBOARD_HTASSWD_FILE} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/k8s.wise-eat.com.https.conf.template" > "${SITE}"
  log "nginx HTTPS k8s → ${K8S_DASHBOARD_BACKEND_HOST}:${K8S_DASHBOARD_BACKEND_PORT}"
else
  envsubst '${K8S_DASHBOARD_DOMAIN} ${K8S_DASHBOARD_BACKEND_HOST} ${K8S_DASHBOARD_BACKEND_PORT} ${K8S_DASHBOARD_HTASSWD_FILE} ${CERTBOT_WEBROOT}' \
    < "${NGINX_CONF_SRC}/k8s.wise-eat.com.http.conf.template" > "${SITE}"
  log "nginx HTTP k8s (ACME + basic auth) → :${K8S_DASHBOARD_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

log "Headlamp public : https://${K8S_DASHBOARD_DOMAIN}/ (basic auth nginx + token Headlamp)"
