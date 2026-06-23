#!/usr/bin/env bash
# Active HTTPS nginx après Certbot (Let's Encrypt).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
[[ -f "/etc/letsencrypt/live/${WISE_EAT_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent — lancer certbot d'abord"

command -v nginx >/dev/null 2>&1 || die "nginx non installé — ./install.sh nginx"

apt install -y gettext-base certbot 2>/dev/null || true
if [[ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]]; then
  mkdir -p /etc/letsencrypt
  certbot install --nginx --cert-name "${WISE_EAT_DOMAIN}" --redirect 2>/dev/null || \
    cp -n "${NGINX_CONF_SRC}/options-ssl-nginx.conf" /etc/letsencrypt/ 2>/dev/null || \
    curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
      -o /etc/letsencrypt/options-ssl-nginx.conf 2>/dev/null || true
fi
if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null || true
fi

SITE="/etc/nginx/sites-available/${WISE_EAT_DOMAIN}"
render_template "${NGINX_CONF_SRC}/wise-eat.cloud.https.conf.template" "${SITE}"
nginx -t
systemctl reload nginx
log "nginx HTTPS activé pour ${WISE_EAT_DOMAIN}"
