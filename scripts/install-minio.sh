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
  MINIO_CONSOLE_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  cp .env.example .env.minio
  sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" .env.minio
  sed -i "s|^MINIO_CONSOLE_BASIC_AUTH_PASSWORD=.*|MINIO_CONSOLE_BASIC_AUTH_PASSWORD=${MINIO_CONSOLE_BASIC_AUTH_PASSWORD}|" .env.minio
  chmod 600 .env.minio
  log "Mot de passe MinIO généré → ${MINIO_DIR}/.env.minio"
fi

if ! grep -q '^MINIO_CONSOLE_BASIC_AUTH_PASSWORD=.' .env.minio 2>/dev/null; then
  MINIO_CONSOLE_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  if grep -q '^MINIO_CONSOLE_BASIC_AUTH_PASSWORD=' .env.minio; then
    sed -i "s|^MINIO_CONSOLE_BASIC_AUTH_PASSWORD=.*|MINIO_CONSOLE_BASIC_AUTH_PASSWORD=${MINIO_CONSOLE_BASIC_AUTH_PASSWORD}|" .env.minio
  else
    echo "MINIO_CONSOLE_BASIC_AUTH_PASSWORD=${MINIO_CONSOLE_BASIC_AUTH_PASSWORD}" >> .env.minio
  fi
  log "Mot de passe basic auth console MinIO généré → .env.minio"
fi

set -a && source .env.minio && set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER manquant dans .env.minio}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD manquant dans .env.minio}"
: "${MINIO_BUCKET:=wise-eat}"

MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
MINIO_CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}"
MINIO_SERVER_URL="${MINIO_SERVER_URL:-https://${MINIO_STORAGE_DOMAIN}}"
MINIO_BROWSER_REDIRECT_URL="${MINIO_BROWSER_REDIRECT_URL:-https://${MINIO_CONSOLE_DOMAIN}}"

ensure_minio_data_volume
persist_minio_env_paths
set -a && source .env.minio && set +a

log "Démarrage MinIO Docker (données : ${MINIO_DATA_DIR})"
docker compose --env-file .env.minio down 2>/dev/null || true
docker compose --env-file .env.minio pull
docker compose --env-file .env.minio up -d

if ! wait_for_minio_local "${MINIO_API_PORT:-9000}" 45; then
  die "MinIO ne répond pas sur :${MINIO_API_PORT:-9000} — voir docker logs wise-eat-minio"
fi

ensure_minio_on_wise_eat_infra || true

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
    warn "nginx MinIO S3 non configuré — lancer : sudo STUNNEL_TLS_EMAIL=... ./install.sh minio-storage"
  bash "${SCRIPT_DIR}/install-minio-console.sh" 2>/dev/null || \
    warn "nginx MinIO Console non configuré — lancer : sudo STUNNEL_TLS_EMAIL=... ./install.sh minio-console"
fi

if [[ "${MINIO_BACKUP_ENABLED:-1}" == "1" ]]; then
  bash "${SCRIPT_DIR}/install-minio-backup.sh"
fi

CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
CONSOLE_AUTH_USER="${MINIO_CONSOLE_BASIC_AUTH_USER:-minio-console}"

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
  MINIO_REPLICA_ENDPOINTS=http://127.0.0.1:9002,http://127.0.0.1:9004

Réplicas (site replication) :
  sudo ./install.sh minio-replication

Volume : ${MINIO_DATA_DIR} (${MINIO_STORAGE_GB:-25}G max)
Backups : ${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio} (mirror quotidien 03:00)
API S3 public : ${MINIO_SERVER_URL}
Console public : https://${CONSOLE_DOMAIN}
  → basic auth nginx : ${CONSOLE_AUTH_USER} (mot de passe dans .env.minio)
  → puis login MinIO : ${MINIO_ROOT_USER}
Console locale : http://127.0.0.1:${CONSOLE_PORT}
TLS : sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh minio-storage minio-console
MinIO installé dans ${MINIO_DIR}
EOF
