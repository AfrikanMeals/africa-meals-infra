#!/usr/bin/env bash
# Let's Encrypt (Certbot) — nginx WS, Redis Stunnel, Grafana console.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/certbot.sh
source "${SCRIPT_DIR}/lib/certbot.sh"

require_root
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"
CERTBOT_METHOD="${CERTBOT_METHOD:-webroot}"
INSTALL_GRAFANA_CERT="${INSTALL_GRAFANA_CERT:-1}"
INSTALL_PROMETHEUS_CERT="${INSTALL_PROMETHEUS_CERT:-1}"

[[ -n "${STUNNEL_TLS_EMAIL}" ]] || \
  die "STUNNEL_TLS_EMAIL requis — ex. STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot"

if [[ "${CERTBOT_METHOD}" != "webroot" ]]; then
  die "Seul webroot est supporté pour le stack multi-services — CERTBOT_METHOD=webroot"
fi

if ! systemctl is-active nginx >/dev/null 2>&1 && ! systemctl is-active apache2 >/dev/null 2>&1; then
  die "nginx ou apache requis — sudo ./install.sh nginx (puis certbot)"
fi

apt update
apt install -y certbot stunnel4 gettext-base

# --- Sites HTTP pour validation ACME ---
if systemctl is-active nginx >/dev/null 2>&1; then
  if [[ ! -f "/etc/nginx/sites-enabled/${WISE_EAT_DOMAIN}" ]]; then
    bash "${SCRIPT_DIR}/install-nginx.sh"
  fi
  bash "${SCRIPT_DIR}/install-redis-tls-acme.sh"
  if [[ "${INSTALL_GRAFANA_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-grafana-console.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_PROMETHEUS_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-prometheus-logs.sh" 2>/dev/null || true
  fi
fi

# --- Certificats ---
log "=== Certificat WS (${WISE_EAT_DOMAIN}) ==="
issue_le_cert "${WISE_EAT_DOMAIN}"

log "=== Certificat Redis Stunnel (${REDIS_TLS_DOMAIN}) ==="
issue_le_cert "${REDIS_TLS_DOMAIN}"

if [[ "${INSTALL_GRAFANA_CERT}" == "1" ]]; then
  log "=== Certificat Grafana (${GRAFANA_CONSOLE_DOMAIN}) ==="
  issue_le_cert "${GRAFANA_CONSOLE_DOMAIN}"
fi

if [[ "${INSTALL_PROMETHEUS_CERT}" == "1" ]]; then
  log "=== Certificat Prometheus (${PROMETHEUS_LOGS_DOMAIN}) ==="
  issue_le_cert "${PROMETHEUS_LOGS_DOMAIN}"
fi

install_certbot_renewal_hook

if systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-nginx-ssl.sh"
  if cert_exists "${GRAFANA_CONSOLE_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-grafana-console-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${PROMETHEUS_LOGS_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-prometheus-logs-ssl.sh" 2>/dev/null || true
  fi
elif systemctl is-active apache2 >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-apache-ssl.sh"
fi

bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"

log "Renouvellement auto : certbot renew (hook → nginx + stunnel4)"
certbot renew --dry-run

log "=== Vérification TLS ==="
bash "${SCRIPT_DIR}/verify-tls.sh" || true
