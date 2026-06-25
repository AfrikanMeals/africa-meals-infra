#!/usr/bin/env bash
# Helpers Certbot partagés — Wise Eat infra.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

certbot_le_dir() {
  echo "/etc/letsencrypt/live/$1"
}

cert_exists() {
  local domain="$1"
  local le_dir
  le_dir="$(certbot_le_dir "${domain}")"
  [[ -f "${le_dir}/fullchain.pem" && -f "${le_dir}/privkey.pem" ]]
}

# issue_le_cert <primary_domain> [extra_domain ...]
# Obtient ou étend un certificat LE via webroot (HTTP-01).
issue_le_cert() {
  local primary="$1"
  shift
  local -a domains=("${primary}" "$@")
  local -a args=()
  local d

  [[ -n "${STUNNEL_TLS_EMAIL:-}" ]] || \
    die "STUNNEL_TLS_EMAIL requis — ex. STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot"

  mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
  chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

  for d in "${domains[@]}"; do
    [[ -n "${d}" ]] || continue
    args+=(-d "${d}")
  done

  if cert_exists "${primary}"; then
    log "Certificat déjà présent pour ${primary} — vérification / extension SAN"
    certbot certonly --webroot \
      -w "${CERTBOT_WEBROOT}" \
      "${args[@]}" \
      --cert-name "${primary}" \
      --email "${STUNNEL_TLS_EMAIL}" \
      --agree-tos \
      --non-interactive \
      --keep-until-expiring \
      --expand
  else
    log "Obtention certificat Let's Encrypt (webroot) : ${domains[*]}"
    certbot certonly --webroot \
      -w "${CERTBOT_WEBROOT}" \
      "${args[@]}" \
      --cert-name "${primary}" \
      --email "${STUNNEL_TLS_EMAIL}" \
      --agree-tos \
      --non-interactive \
      --keep-until-expiring
  fi
}

install_certbot_renewal_hook() {
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  local hook="${hook_dir}/wise-eat-tls.sh"
  mkdir -p "${hook_dir}"
  cat > "${hook}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export WISE_EAT_DOMAIN=${WISE_EAT_DOMAIN}
export REDIS_TLS_DOMAIN=${REDIS_TLS_DOMAIN}
export GRAFANA_CONSOLE_DOMAIN=${GRAFANA_CONSOLE_DOMAIN}
export PROMETHEUS_LOGS_DOMAIN=${PROMETHEUS_LOGS_DOMAIN}
export MINIO_STORAGE_DOMAIN=${MINIO_STORAGE_DOMAIN}
export MINIO_CONSOLE_DOMAIN=${MINIO_CONSOLE_DOMAIN}
export INFRA_ROOT=${INFRA_ROOT}
bash ${INFRA_ROOT}/scripts/sync-stunnel-certs.sh
if systemctl is-active nginx >/dev/null 2>&1; then
  WISE_EAT_DOMAIN=${WISE_EAT_DOMAIN} bash ${INFRA_ROOT}/scripts/enable-nginx-ssl.sh
  if [[ -f "/etc/letsencrypt/live/${GRAFANA_CONSOLE_DOMAIN}/fullchain.pem" ]]; then
    bash ${INFRA_ROOT}/scripts/enable-grafana-console-ssl.sh 2>/dev/null || true
  fi
  if [[ -f "/etc/letsencrypt/live/${PROMETHEUS_LOGS_DOMAIN}/fullchain.pem" ]]; then
    bash ${INFRA_ROOT}/scripts/enable-prometheus-logs-ssl.sh 2>/dev/null || true
  fi
  if [[ -f "/etc/letsencrypt/live/${MINIO_STORAGE_DOMAIN}/fullchain.pem" ]]; then
    bash ${INFRA_ROOT}/scripts/enable-minio-storage-ssl.sh 2>/dev/null || true
  fi
  if [[ -f "/etc/letsencrypt/live/${MINIO_CONSOLE_DOMAIN}/fullchain.pem" ]]; then
    bash ${INFRA_ROOT}/scripts/enable-minio-console-ssl.sh 2>/dev/null || true
  fi
fi
if systemctl is-active apache2 >/dev/null 2>&1; then
  WISE_EAT_DOMAIN=${WISE_EAT_DOMAIN} bash ${INFRA_ROOT}/scripts/enable-apache-ssl.sh
fi
EOF
  chmod +x "${hook}"
  log "Hook renouvellement : ${hook}"
}

verify_tls_cert() {
  local label="$1"
  local domain="$2"
  local port="${3:-443}"
  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  if ! echo | openssl s_client -connect "${domain}:${port}" -servername "${domain}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null; then
    warn "${label} : impossible de lire le certificat ${domain}:${port}"
    return 1
  fi
}
