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
INSTALL_MONGODB_TLS_CERT="${INSTALL_MONGODB_TLS_CERT:-1}"
INSTALL_MONGODB_ADMIN_CERT="${INSTALL_MONGODB_ADMIN_CERT:-1}"
INSTALL_NEO4J_ADMIN_CERT="${INSTALL_NEO4J_ADMIN_CERT:-1}"
INSTALL_OLLAMA_CERT="${INSTALL_OLLAMA_CERT:-1}"
INSTALL_MATOMO_CERT="${INSTALL_MATOMO_CERT:-1}"
INSTALL_API_CERT="${INSTALL_API_CERT:-1}"
INSTALL_HAPROXY_PROXY_CERT="${INSTALL_HAPROXY_PROXY_CERT:-1}"
K8S_API_NGINX="${INFRA_ROOT}/k8s/scripts/install-api-nginx.sh"

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
  if [[ "${INSTALL_MONGODB_TLS_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-mongodb-tls-acme.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_MONGODB_ADMIN_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-mongodb-admin.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_NEO4J_ADMIN_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-neo4j-admin.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_OLLAMA_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-ollama-gateway.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_MATOMO_CERT}" == "1" ]]; then
    bash "${SCRIPT_DIR}/install-matomo-gateway.sh" 2>/dev/null || true
  fi
  if [[ "${INSTALL_API_CERT}" == "1" && -x "${K8S_API_NGINX}" ]]; then
    bash "${K8S_API_NGINX}" 2>/dev/null || true
  fi
  if command -v k3s >/dev/null 2>&1 && [[ -x "${INFRA_ROOT}/k8s/scripts/install-ws-nginx.sh" ]]; then
    bash "${INFRA_ROOT}/k8s/scripts/install-ws-nginx.sh" 2>/dev/null || true
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

if [[ "${INSTALL_HAPROXY_PROXY_CERT}" == "1" ]]; then
  log "=== Certificat HAProxy UI (${HAPROXY_PROXY_DOMAIN}) ==="
  bash "${SCRIPT_DIR}/install-haproxy-proxy.sh" 2>/dev/null || true
  issue_le_cert "${HAPROXY_PROXY_DOMAIN}"
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

if [[ "${INSTALL_MONGODB_TLS_CERT}" == "1" ]]; then
  log "=== Certificat MongoDB TLS (${MONGO_TLS_DOMAIN}) ==="
  issue_le_cert "${MONGO_TLS_DOMAIN}"
fi

if [[ "${INSTALL_MONGODB_ADMIN_CERT}" == "1" ]]; then
  log "=== Certificat MongoDB Admin (${MONGO_ADMIN_DOMAIN}) ==="
  issue_le_cert "${MONGO_ADMIN_DOMAIN}"
fi

if [[ "${INSTALL_NEO4J_ADMIN_CERT}" == "1" ]]; then
  log "=== Certificat Neo4j Admin (${NEO4J_ADMIN_DOMAIN}) ==="
  issue_le_cert "${NEO4J_ADMIN_DOMAIN}"
fi

if [[ "${INSTALL_OLLAMA_CERT}" == "1" ]]; then
  log "=== Certificat Ollama gateway (${OLLAMA_GATEWAY_DOMAIN}) ==="
  issue_le_cert "${OLLAMA_GATEWAY_DOMAIN}"
fi

if [[ "${INSTALL_MATOMO_CERT}" == "1" ]]; then
  log "=== Certificat Matomo (${MATOMO_DOMAIN}) ==="
  issue_le_cert "${MATOMO_DOMAIN}"
fi

if [[ "${INSTALL_API_CERT}" == "1" ]]; then
  log "=== Certificat API Nest (${API_WISE_EAT_DOMAIN}) ==="
  issue_le_cert "${API_WISE_EAT_DOMAIN}"
fi

if command -v k3s >/dev/null 2>&1; then
  if cert_exists "${WS_WISE_EAT_DOMAIN}"; then
    log "=== Certificat WS k8s (${WS_WISE_EAT_DOMAIN}) ==="
    issue_le_cert "${WS_WISE_EAT_DOMAIN}"
  fi
fi

install_certbot_renewal_hook

if systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-nginx-ssl.sh"
  if cert_exists "${GRAFANA_CONSOLE_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-grafana-console-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${HAPROXY_PROXY_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-haproxy-proxy-ssl.sh" 2>/dev/null || true
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
  if cert_exists "${MONGO_TLS_DOMAIN}"; then
    bash "${SCRIPT_DIR}/sync-mongodb-stunnel-certs.sh" 2>/dev/null || true
    bash "${SCRIPT_DIR}/install-mongodb-tls.sh" 2>/dev/null || true
  fi
  if cert_exists "${MONGO_ADMIN_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-mongodb-admin-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${NEO4J_ADMIN_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-neo4j-admin-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${OLLAMA_GATEWAY_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-ollama-gateway-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${MATOMO_DOMAIN}"; then
    bash "${SCRIPT_DIR}/enable-matomo-ssl.sh" 2>/dev/null || true
  fi
  if cert_exists "${API_WISE_EAT_DOMAIN}" && [[ -x "${INFRA_ROOT}/k8s/scripts/install-api-nginx.sh" ]]; then
    bash "${INFRA_ROOT}/k8s/scripts/install-api-nginx.sh" 2>/dev/null || true
  fi
  if cert_exists "${WS_WISE_EAT_DOMAIN}" && [[ -x "${INFRA_ROOT}/k8s/scripts/install-ws-nginx.sh" ]]; then
    bash "${INFRA_ROOT}/k8s/scripts/install-ws-nginx.sh" 2>/dev/null || true
  fi
elif systemctl is-active apache2 >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/enable-apache-ssl.sh"
fi

bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"

log "Renouvellement auto : certbot renew (hook → nginx + stunnel4)"
certbot renew --dry-run

log "=== Vérification TLS ==="
bash "${SCRIPT_DIR}/verify-tls.sh" || true
