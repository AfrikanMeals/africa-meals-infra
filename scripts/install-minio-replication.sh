#!/usr/bin/env bash
# MinIO — 2 réplicas + site replication (mc admin replicate)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/minio-storage.sh
source "${SCRIPT_DIR}/lib/minio-storage.sh"
# shellcheck source=lib/minio-replication.sh
source "${SCRIPT_DIR}/lib/minio-replication.sh"

require_root
sync_component minio
cd "${MINIO_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.minio ]]; then
  die "MinIO non installé — lancer d'abord : sudo ./install.sh minio"
fi

set -a && source .env.minio && set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER manquant dans .env.minio}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD manquant dans .env.minio}"
: "${MINIO_BUCKET:=wise-eat}"

MINIO_REPLICA_1_API_PORT="${MINIO_REPLICA_1_API_PORT:-9002}"
MINIO_REPLICA_2_API_PORT="${MINIO_REPLICA_2_API_PORT:-9004}"
MINIO_REPLICA_1_DATA_DIR="${MINIO_REPLICA_1_DATA_DIR:-/var/lib/wise-eat/minio-replica-1}"
MINIO_REPLICA_2_DATA_DIR="${MINIO_REPLICA_2_DATA_DIR:-/var/lib/wise-eat/minio-replica-2}"
MINIO_REPLICA_1_SERVER_URL="${MINIO_REPLICA_1_SERVER_URL:-http://127.0.0.1:${MINIO_REPLICA_1_API_PORT}}"
MINIO_REPLICA_2_SERVER_URL="${MINIO_REPLICA_2_SERVER_URL:-http://127.0.0.1:${MINIO_REPLICA_2_API_PORT}}"

ensure_minio_replica_data_volume 1
ensure_minio_replica_data_volume 2
persist_minio_env_paths
set -a && source .env.minio && set +a

if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-minio'; then
  log "Primaire MinIO absent — démarrage via install-minio"
  bash "${SCRIPT_DIR}/install-minio.sh"
  set -a && source .env.minio && set +a
fi

log "Démarrage MinIO primaire + 2 réplicas (site replication)"
docker compose --env-file .env.minio \
  -f docker-compose.yml \
  -f docker-compose.replicas.yml pull
docker compose --env-file .env.minio \
  -f docker-compose.yml \
  -f docker-compose.replicas.yml up -d

if ! wait_for_minio_local "${MINIO_API_PORT:-9000}" 45; then
  die "MinIO primaire ne répond pas sur :${MINIO_API_PORT:-9000}"
fi
if ! wait_for_minio_local "${MINIO_REPLICA_1_API_PORT}" 45; then
  die "MinIO réplica 1 ne répond pas sur :${MINIO_REPLICA_1_API_PORT}"
fi
if ! wait_for_minio_local "${MINIO_REPLICA_2_API_PORT}" 45; then
  die "MinIO réplica 2 ne répond pas sur :${MINIO_REPLICA_2_API_PORT}"
fi

ensure_minio_on_wise_eat_infra || true
configure_minio_site_replication_mc

MINIO_REPLICA_1_STORAGE_DOMAIN="${MINIO_REPLICA_1_STORAGE_DOMAIN:-dr1-storage.wise-eat.com}"
MINIO_REPLICA_2_STORAGE_DOMAIN="${MINIO_REPLICA_2_STORAGE_DOMAIN:-dr2-storage.wise-eat.com}"
MINIO_REPLICA_1_SERVER_URL="${MINIO_REPLICA_1_SERVER_URL:-https://${MINIO_REPLICA_1_STORAGE_DOMAIN}}"
MINIO_REPLICA_2_SERVER_URL="${MINIO_REPLICA_2_SERVER_URL:-https://${MINIO_REPLICA_2_STORAGE_DOMAIN}}"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  log "nginx reverse-proxy réplicas MinIO (${MINIO_REPLICA_1_STORAGE_DOMAIN}, ${MINIO_REPLICA_2_STORAGE_DOMAIN})"
  MINIO_STORAGE_DOMAIN="${MINIO_REPLICA_1_STORAGE_DOMAIN}" \
    MINIO_BACKEND_PORT="${MINIO_REPLICA_1_API_PORT}" \
    bash "${SCRIPT_DIR}/install-minio-storage.sh" 2>/dev/null || \
    warn "nginx ${MINIO_REPLICA_1_STORAGE_DOMAIN} non configuré — DNS A + sudo STUNNEL_TLS_EMAIL=... ./install.sh minio-replication"
  MINIO_STORAGE_DOMAIN="${MINIO_REPLICA_2_STORAGE_DOMAIN}" \
    MINIO_BACKEND_PORT="${MINIO_REPLICA_2_API_PORT}" \
    bash "${SCRIPT_DIR}/install-minio-storage.sh" 2>/dev/null || \
    warn "nginx ${MINIO_REPLICA_2_STORAGE_DOMAIN} non configuré"
fi

API_PORT="${MINIO_API_PORT:-9000}"
PUBLIC_BASE="${MINIO_SERVER_URL:-https://storage.wise-eat.com}"
REPLICA_ENDPOINTS="${MINIO_REPLICA_1_SERVER_URL},${MINIO_REPLICA_2_SERVER_URL}"

cat <<EOF

MinIO site replication — primaire + 2 réplicas actifs.

API / africa-meals-api (.env prod) :
  MINIO_ENDPOINT=${PUBLIC_BASE}
  MINIO_REPLICA_ENDPOINTS=${REPLICA_ENDPOINTS}
  MINIO_PUBLIC_BASE_URL=${PUBLIC_BASE}/${MINIO_BUCKET}

Réplicas publics :
  ${MINIO_REPLICA_1_STORAGE_DOMAIN} → 127.0.0.1:${MINIO_REPLICA_1_API_PORT}
  ${MINIO_REPLICA_2_STORAGE_DOMAIN} → 127.0.0.1:${MINIO_REPLICA_2_API_PORT}

Réplicas locaux (debug) :
  http://127.0.0.1:${MINIO_REPLICA_1_API_PORT}  http://127.0.0.1:${MINIO_REPLICA_2_API_PORT}

Volumes :
  primaire : ${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}
  réplica 1 : ${MINIO_REPLICA_1_DATA_DIR}
  réplica 2 : ${MINIO_REPLICA_2_DATA_DIR}

Écritures API → primaire uniquement ; lectures avec failover vers réplicas.
Site replication MinIO propage buckets/objets/IAM entre les 3 sites.

Console Site Replication : utiliser des endpoints HTTPS publics résolvables
(ex. https://storage.wise-eat.com), pas des hostnames Docker internes.
EOF
