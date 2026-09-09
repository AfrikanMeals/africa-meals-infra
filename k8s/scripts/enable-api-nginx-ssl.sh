#!/usr/bin/env bash
# Certificat Let's Encrypt + HTTPS pour api.wise-eat.com (+ SAN alias apis) → k3s :30900
#
# Usage :
#   sudo STUNNEL_TLS_EMAIL=help@wise-eat.com k8s/scripts/enable-api-nginx-ssl.sh
#
# Prérequis DNS (Cloudflare Proxied OK) :
#   api.wise-eat.com  → IP VPS
#   apis.wise-eat.com  → même IP VPS (pas de Worker Custom Domain sur apis)
# SSL/TLS zone : Full (strict)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/certbot.sh
source "${INFRA_ROOT}/scripts/lib/certbot.sh"

require_root

API_WISE_EAT_DOMAIN="${API_WISE_EAT_DOMAIN:-api.wise-eat.com}"
API_WISE_EAT_ALIAS_DOMAIN="${API_WISE_EAT_ALIAS_DOMAIN-apis.wise-eat.com}"

[[ -n "${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}" ]] || \
  die "Définir STUNNEL_TLS_EMAIL ou CERTBOT_EMAIL"

# Harmoniser l’email Certbot si seul CERTBOT_EMAIL est fourni.
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL}}"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_letsencrypt_nginx_tls_files

# 1. Vhost HTTP avec les deux server_name (ACME webroot doit répondre pour apis aussi).
"${SCRIPT_DIR}/install-api-nginx.sh"

# 2. Émettre / étendre le cert primaire api avec SAN alias (évite Cloudflare 526 Full strict).
if [[ -n "${API_WISE_EAT_ALIAS_DOMAIN}" ]]; then
  log "Cert LE ${API_WISE_EAT_DOMAIN} + SAN ${API_WISE_EAT_ALIAS_DOMAIN}"
  issue_le_cert "${API_WISE_EAT_DOMAIN}" "${API_WISE_EAT_ALIAS_DOMAIN}"
else
  issue_le_cert "${API_WISE_EAT_DOMAIN}"
fi

# 3. Repasser en HTTPS une fois fullchain présent.
"${SCRIPT_DIR}/install-api-nginx.sh"

log "HTTPS API actif : https://${API_WISE_EAT_DOMAIN}/health"
if [[ -n "${API_WISE_EAT_ALIAS_DOMAIN}" ]]; then
  log "HTTPS alias : https://${API_WISE_EAT_ALIAS_DOMAIN}/health"
fi
log "Vérifier : curl -sI https://${API_WISE_EAT_DOMAIN}/health | head -5"
if [[ -n "${API_WISE_EAT_ALIAS_DOMAIN}" ]]; then
  log "Vérifier alias : curl -sI https://${API_WISE_EAT_ALIAS_DOMAIN}/health | head -5"
  log "SAN : openssl s_client -connect ${API_WISE_EAT_ALIAS_DOMAIN}:443 -servername ${API_WISE_EAT_ALIAS_DOMAIN} </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName"
fi
