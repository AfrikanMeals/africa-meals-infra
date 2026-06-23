#!/usr/bin/env bash
# Active HTTPS apache après Certbot (Let's Encrypt).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
[[ -f "/etc/letsencrypt/live/${WISE_EAT_DOMAIN}/fullchain.pem" ]] || \
  die "Certificat absent — lancer certbot d'abord"

command -v apache2 >/dev/null 2>&1 || die "apache2 non installé — ./install.sh apache"

SITE="/etc/apache2/sites-available/${WISE_EAT_DOMAIN}.conf"
render_template "${APACHE_CONF_SRC}/wise-eat.cloud.https.conf.template" "${SITE}"
apache2ctl configtest
systemctl reload apache2
log "apache2 HTTPS activé pour ${WISE_EAT_DOMAIN}"
