#!/usr/bin/env bash
# nginx :80 pour HTTP-01 Certbot sur db.wise-eat.com (Stunnel MongoDB TLS).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${MONGO_TLS_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${MONGO_TLS_DOMAIN}"

export MONGO_TLS_DOMAIN CERTBOT_WEBROOT
envsubst '${MONGO_TLS_DOMAIN} ${CERTBOT_WEBROOT}' \
  < "${NGINX_CONF_SRC}/db.wise-eat.com.http.conf.template" > "${SITE}"

ln -sf "${SITE}" "${ENABLED}"
nginx_test_and_reload

log "Webroot Certbot actif pour MongoDB TLS (${MONGO_TLS_DOMAIN}:80 → ${CERTBOT_WEBROOT})"
