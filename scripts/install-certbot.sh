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
INSTALL_MINIO_STORAGE_CERT="${INSTALL_MINIO_STORAGE_CERT:-1}"
INSTALL_MINIO_CONSOLE_CERT="${INSTALL_MINIO_CONSOLE_CERT:-1}"
INSTALL_EMQX_BROKER_CERT="${INSTALL_EMQX_BROKER_CERT:-1}"
INSTALL_EMQX_WORKER_CERT="${INSTALL_EMQX_WORKER_CERT:-1}"

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
  if [[ "${INSTALL_MINIO_STORAGE_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-minio-storage.sh" 2>/dev/null || true
    bash "${SCRIPT_DIR}/install-minio-replica-storage.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_MINIO_CONSOLE_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-minio-console.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_EMQX_BROKER_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-emqx-broker.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_EMQX_WORKER_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-emqx-worker.sh" 2>/dev/null || true
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

if [[ "${INSTALL_MINIO_STORAGE_CERT}" == "1" ]]; then
  log "=== Certificat MinIO S3 (${MINIO_STORAGE_DOMAIN}) ==="
  issue_le_cert "${MINIO_STORAGE_DOMAIN}"
fi

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
fi
MINIO_REPLICA_1_STORAGE_DOMAIN="${MINIO_REPLICA_1_STORAGE_DOMAIN:-dr1-storage.wise-eat.com}"
MINIO_REPLICA_2_STORAGE_DOMAIN="${MINIO_REPLICA_2_STORAGE_DOMAIN:-dr2-storage.wise-eat.com}"
if [[ "${INSTALL_MINIO_STORAGE_CERT}" == "1" ]]; then
  if cert_exists "${MINIO_REPLICA_1_STORAGE_DOMAIN}" || [[ -f "/etc/nginx/sites-enabled/${MINIO_REPLICA_1_STORAGE_DOMAIN}" ]]; then
    log "=== Certificat MinIO réplica 1 (${MINIO_REPLICA_1_STORAGE_DOMAIN}) ==="
    issue_le_cert "${MINIO_REPLICA_1_STORAGE_DOMAIN}"
  fi
  if cert_exists "${MINIO_REPLICA_2_STORAGE_DOMAIN}" || [[ -f "/etc/nginx/sites-enabled/${MINIO_REPLICA_2_STORAGE_DOMAIN}" ]]; then
    log "=== Certificat MinIO réplica 2 (${MINIO_REPLICA_2_STORAGE_DOMAIN}) ==="
    issue_le_cert "${MINIO_REPLICA_2_STORAGE_DOMAIN}"
  fi
fi

if [[ "${INSTALL_MINIO_CONSOLE_CERT}" == "1" ]]; then
  log "=== Certificat MinIO Console (${MINIO_CONSOLE_DOMAIN}) ==="
  issue_le_cert "${MINIO_CONSOLE_DOMAIN}"
fi

if [[ "${INSTALL_EMQX_BROKER_CERT}" == "1" ]]; then
  log "=== Certificat EMQX broker (${EMQX_BROKER_DOMAIN}) ==="
  issue_le_cert "${EMQX_BROKER_DOMAIN}"
fi

if [[ "${INSTALL_EMQX_WORKER_CERT}" == "1" ]]; then
  log "=== Certificat EMQX Dashboard (${EMQX_WORKER_DOMAIN}) ==="
  issue_le_cert "${EMQX_WORKER_DOMAIN}"
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
  if cert_exists "${MINIO_STORAGE_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-minio-storage-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${MINIO_REPLICA_1_STORAGE_DOMAIN}"; then
    MINIO_STORAGE_DOMAIN="${MINIO_REPLICA_1_STORAGE_DOMAIN}" \
      MINIO_BACKEND_PORT="${MINIO_REPLICA_1_API_PORT:-9002}" \
      bash "${SCRIPT_DIR}/enable-minio-storage-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${MINIO_REPLICA_2_STORAGE_DOMAIN}"; then
    MINIO_STORAGE_DOMAIN="${MINIO_REPLICA_2_STORAGE_DOMAIN}" \
      MINIO_BACKEND_PORT="${MINIO_REPLICA_2_API_PORT:-9004}" \
      bash "${SCRIPT_DIR}/enable-minio-storage-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${MINIO_CONSOLE_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-minio-console-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${EMQX_BROKER_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-emqx-broker-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${EMQX_WORKER_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-emqx-worker-ssl.sh" 2>/dev/null || true
  fi
elif systemctl is-active apache2 >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-apache-ssl.sh"
fi

bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"

log "Renouvellement auto : certbot renew (hook → nginx + stunnel4)"
certbot renew --dry-run

log "=== Vérification TLS ==="
bash "${SCRIPT_DIR}/verify-tls.sh" || true
