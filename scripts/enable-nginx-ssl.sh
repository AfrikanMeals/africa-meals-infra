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

ensure_letsencrypt_nginx_tls_files

SITE="/etc/nginx/sites-available/${WISE_EAT_DOMAIN}"
render_template "${NGINX_CONF_SRC}/wise-eat.cloud.https.conf.template" "${SITE}"
nginx -t
systemctl reload nginx
log "nginx HTTPS activé pour ${WISE_EAT_DOMAIN}"
