#!/usr/bin/env bash
# Let's Encrypt (Certbot) — nginx/apache webroot + Stunnel Redis TLS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"
CERTBOT_METHOD="${CERTBOT_METHOD:-webroot}"

[[ -n "${STUNNEL_TLS_EMAIL}" ]] || \
  die "STUNNEL_TLS_EMAIL requis — ex. STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot"

if [[ "${CERTBOT_METHOD}" == "webroot" ]]; then
  if ! systemctl is-active nginx >/dev/null 2>&1 && ! systemctl is-active apache2 >/dev/null 2>&1; then
    warn "Aucun serveur web actif — lancer ./install.sh nginx (ou apache) avant certbot webroot"
  fi
fi

apt update
apt install -y certbot stunnel4

if [[ -d "/etc/letsencrypt/live/${STUNNEL_TLS_DOMAIN}" ]]; then
  log "Certificat déjà présent pour ${STUNNEL_TLS_DOMAIN}"
else
  log "Obtention certificat Let's Encrypt (${CERTBOT_METHOD}) pour ${STUNNEL_TLS_DOMAIN}"
  case "${CERTBOT_METHOD}" in
    webroot)
      mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
      certbot certonly --webroot \
        -w "${CERTBOT_WEBROOT}" \
        -d "${STUNNEL_TLS_DOMAIN}" \
        --email "${STUNNEL_TLS_EMAIL}" \
        --agree-tos \
        --non-interactive \
        --keep-until-expiring
      ;;
    standalone)
      warn "standalone : port 80 libre requis (arrêter nginx/apache momentanément)"
      certbot certonly --standalone \
        -d "${STUNNEL_TLS_DOMAIN}" \
        --email "${STUNNEL_TLS_EMAIL}" \
        --agree-tos \
        --non-interactive \
        --preferred-challenges http \
        --keep-until-expiring
      ;;
    *)
      die "CERTBOT_METHOD invalide : ${CERTBOT_METHOD} (webroot|standalone)"
      ;;
  esac
fi

HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
HOOK="${HOOK_DIR}/wise-eat-tls.sh"
mkdir -p "${HOOK_DIR}"
cat > "${HOOK}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STUNNEL_TLS_DOMAIN=${STUNNEL_TLS_DOMAIN} WISE_EAT_DOMAIN=${WISE_EAT_DOMAIN} \\
  bash ${INFRA_ROOT}/scripts/sync-stunnel-certs.sh
if systemctl is-active nginx >/dev/null 2>&1; then
  WISE_EAT_DOMAIN=${WISE_EAT_DOMAIN} bash ${INFRA_ROOT}/scripts/enable-nginx-ssl.sh
elif systemctl is-active apache2 >/dev/null 2>&1; then
  WISE_EAT_DOMAIN=${WISE_EAT_DOMAIN} bash ${INFRA_ROOT}/scripts/enable-apache-ssl.sh
fi
EOF
chmod +x "${HOOK}"

if systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-nginx-ssl.sh"
elif systemctl is-active apache2 >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-apache-ssl.sh"
fi

bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"

log "Renouvellement auto : certbot renew (hook → nginx/apache + stunnel4)"
certbot renew --dry-run
