#!/usr/bin/env bash
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
  MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  cp .env.example .env.minio
  sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" .env.minio
  chmod 600 .env.minio
  log "Mot de passe MinIO généré → ${MINIO_DIR}/.env.minio"
fi

set -a && source .env.minio && set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER manquant dans .env.minio}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD manquant dans .env.minio}"
: "${MINIO_BUCKET:=wise-eat}"

MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}"
MINIO_SERVER_URL="${MINIO_SERVER_URL:-https://${MINIO_STORAGE_DOMAIN}}"

ensure_minio_data_volume
persist_minio_env_paths
set -a && source .env.minio && set +a

log "Démarrage MinIO Docker (données : ${MINIO_DATA_DIR})"
docker compose --env-file .env.minio down 2>/dev/null || true
docker compose --env-file .env.minio pull
docker compose --env-file .env.minio up -d

wait_for_minio() {
  local port="${MINIO_API_PORT:-9000}"
  for _ in $(seq 1 45); do
    if curl -sf "http://127.0.0.1:${port}/minio/health/live" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! wait_for_minio; then
  die "MinIO ne répond pas sur :${MINIO_API_PORT:-9000} — voir docker logs wise-eat-minio"
fi

log "Initialisation bucket MinIO (${MINIO_BUCKET})"
docker run --rm --network wise-eat-minio \
  --entrypoint /bin/sh \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  -e MINIO_BUCKET \
  -e MINIO_PUBLIC_READ="${MINIO_PUBLIC_READ:-true}" \
  minio/mc:RELEASE.2024-10-08T09-37-26Z \
  -c '
    set -e
    mc alias set local http://minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
    mc mb --ignore-existing "local/${MINIO_BUCKET}"
    if [ "${MINIO_PUBLIC_READ}" = "true" ]; then
      mc anonymous set download "local/${MINIO_BUCKET}" || true
    fi
  '

docker compose --env-file .env.minio ps

API_PORT="${MINIO_API_PORT:-9000}"
CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
REGION="${MINIO_REGION:-us-east-1}"
PUBLIC_BASE="${MINIO_SERVER_URL}/${MINIO_BUCKET}"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-minio-storage.sh" 2>/dev/null || \
    warn "nginx MinIO non configuré — lancer : sudo STUNNEL_TLS_EMAIL=... ./install.sh minio-storage"
fi

if [[ "${MINIO_BACKUP_ENABLED:-1}" == "1" ]]; then
  bash "${SCRIPT_DIR}/install-minio-backup.sh"
fi

cat <<EOF

API / africa-meals-api (.env prod VPS) :
  MINIO_ENDPOINT=${MINIO_SERVER_URL}
  MINIO_BUCKET=${MINIO_BUCKET}
  MINIO_ACCESS_KEY=${MINIO_ROOT_USER}
  MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD}
  MINIO_REGION=${REGION}
  MINIO_FORCE_PATH_STYLE=true
  MINIO_PUBLIC_READ=${MINIO_PUBLIC_READ:-true}
  MINIO_PUBLIC_BASE_URL=${PUBLIC_BASE}

API locale (même VPS, sans TLS) :
  MINIO_ENDPOINT=http://127.0.0.1:${API_PORT}

Volume : ${MINIO_DATA_DIR} (${MINIO_STORAGE_GB:-25}G max)
Backups : ${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio} (mirror quotidien 03:00)
Console MinIO : http://127.0.0.1:${CONSOLE_PORT} (localhost uniquement)
Public : ${MINIO_SERVER_URL}
TLS : sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh minio-storage
MinIO installé dans ${MINIO_DIR}
EOF
