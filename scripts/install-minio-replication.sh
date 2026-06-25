#!/usr/bin/env bash
# MinIO — 2 réplicas + site replication (mc admin replicate)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/minio-storage.sh
source "${SCRIPT_DIR}/lib/minio-storage.sh"

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

log "Configuration site replication (mc admin replicate)"
docker run --rm --network wise-eat-minio \
  --entrypoint /bin/sh \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  -e MINIO_BUCKET \
  -e MINIO_PUBLIC_READ="${MINIO_PUBLIC_READ:-true}" \
  minio/mc:RELEASE.2024-10-08T09-37-26Z \
  -c '
    set -e
    mc alias set primary http://wise-eat-minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
    mc alias set replica1 http://wise-eat-minio-replica-1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
    mc alias set replica2 http://wise-eat-minio-replica-2:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

    for site in primary replica1 replica2; do
      mc mb --ignore-existing "${site}/${MINIO_BUCKET}"
      if [ "${MINIO_PUBLIC_READ}" = "true" ]; then
        mc anonymous set download "${site}/${MINIO_BUCKET}" || true
      fi
    done

    if mc admin replicate info primary 2>/dev/null | grep -qiE "enabled|replica"; then
      echo "Site replication déjà active"
      mc admin replicate info primary || true
    else
      mc admin replicate add primary replica1 replica2 \
        || { mc admin replicate add primary replica1; mc admin replicate add primary replica2; }
      mc admin replicate info primary
    fi
  '

API_PORT="${MINIO_API_PORT:-9000}"
REPLICA_ENDPOINTS="http://127.0.0.1:${MINIO_REPLICA_1_API_PORT},http://127.0.0.1:${MINIO_REPLICA_2_API_PORT}"

cat <<EOF

MinIO site replication — primaire + 2 réplicas actifs.

API / africa-meals-api (.env prod VPS, même machine) :
  MINIO_ENDPOINT=http://127.0.0.1:${API_PORT}
  MINIO_REPLICA_ENDPOINTS=${REPLICA_ENDPOINTS}
  MINIO_PUBLIC_BASE_URL=${MINIO_SERVER_URL:-https://storage.wise-eat.com}/${MINIO_BUCKET}

Réplicas locaux :
  réplica 1 API : http://127.0.0.1:${MINIO_REPLICA_1_API_PORT} (console :9012)
  réplica 2 API : http://127.0.0.1:${MINIO_REPLICA_2_API_PORT} (console :9014)

Volumes :
  primaire : ${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}
  réplica 1 : ${MINIO_REPLICA_1_DATA_DIR}
  réplica 2 : ${MINIO_REPLICA_2_DATA_DIR}

Écritures API → primaire uniquement ; lectures avec failover vers réplicas.
Site replication MinIO propage buckets/objets/IAM entre les 3 sites.

Console Site Replication : utiliser des endpoints HTTPS publics résolvables
(ex. https://storage.wise-eat.com), pas des hostnames Docker internes.
EOF
