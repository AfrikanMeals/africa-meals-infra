#!/usr/bin/env bash
# nginx :80 pour HTTP-01 Certbot sur le hostname Redis (cache.wise-eat.com).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${REDIS_TLS_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${REDIS_TLS_DOMAIN}"

REDIS_TLS_DOMAIN CERTBOT_WEBROOT \
  envsubst '${REDIS_TLS_DOMAIN} ${CERTBOT_WEBROOT}' \
  < "${NGINX_CONF_SRC}/cache.wise-eat.com.http.conf.template" > "${SITE}"

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

log "Webroot Certbot actif pour Redis TLS (${REDIS_TLS_DOMAIN}:80 → ${CERTBOT_WEBROOT})"
