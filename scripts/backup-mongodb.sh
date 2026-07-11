#!/usr/bin/env bash
# Sauvegarde MongoDB — dump quotidien (override latest/) + snapshot hebdomadaire (hardlinks rsync).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

[[ -f "${MONGODB_ENV}" ]] || die "Fichier absent : ${MONGODB_ENV} — lancer sudo ./install.sh mongodb"

if grep -qE '^MONGO_BACKUP_CRON=30 3' "${MONGODB_ENV}" 2>/dev/null; then
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' "${MONGODB_ENV}"
fi

set -a && source "${MONGODB_ENV}" && set +a

: "${MONGO_ROOT_USER:?MONGO_ROOT_USER manquant}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD manquant}"

MONGO_BACKUP_DIR="${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}"
MONGO_BACKUP_RETENTION_DAYS="${MONGO_BACKUP_RETENTION_DAYS:-30}"
MONGO_BACKUP_SNAPSHOT_WEEKDAY="${MONGO_BACKUP_SNAPSHOT_WEEKDAY:-7}"
MONGO_REPLICA_SET="${MONGO_REPLICA_SET:-rs0}"
STAMP="$(date +%Y-%m-%d)"
DUMP_IMAGE="${MONGO_DUMP_IMAGE:-mongo:8.0}"

mkdir -p "${MONGO_BACKUP_DIR}/latest" "${MONGO_BACKUP_DIR}/snapshots"
chmod 700 "${MONGO_BACKUP_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-mongo-1$'; then
  die "Conteneur wise-eat-mongo-1 arrêté — impossible de sauvegarder"
fi

LATEST_DIR="${MONGO_BACKUP_DIR}/latest"
STAGING="${MONGO_BACKUP_DIR}/.staging-${STAMP}"

log "Dump incrémental (override) → ${LATEST_DIR}/"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"

docker exec wise-eat-mongo-1 mongodump \
  --username="${MONGO_ROOT_USER}" \
  --password="${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase=admin \
  --db="${MONGO_APP_DATABASE:-wise_eat_db}" \
  --gzip \
  --oplog \
  --out="/data/db/.backup-staging" 2>/dev/null || \
docker exec wise-eat-mongo-1 mongodump \
  --username="${MONGO_ROOT_USER}" \
  --password="${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase=admin \
  --gzip \
  --oplog \
  --out="/data/db/.backup-staging"

docker cp "wise-eat-mongo-1:/data/db/.backup-staging/." "${STAGING}/"
docker exec wise-eat-mongo-1 rm -rf /data/db/.backup-staging 2>/dev/null || true

if [[ -z "$(ls -A "${STAGING}" 2>/dev/null || true)" ]]; then
  die "Dump vide — vérifier authentification et replica set"
fi

rm -rf "${LATEST_DIR:?}"/*
mv "${STAGING}"/* "${LATEST_DIR}/"
rmdir "${STAGING}" 2>/dev/null || true

WEEKDAY="$(date +%u)"
if [[ "${WEEKDAY}" == "${MONGO_BACKUP_SNAPSHOT_WEEKDAY}" ]]; then
  SNAP="${MONGO_BACKUP_DIR}/snapshots/${STAMP}"
  if [[ ! -d "${SNAP}" ]]; then
    log "Snapshot hebdomadaire complet (hardlinks) → ${SNAP}"
    mkdir -p "${SNAP}"
    rsync -a --delete --link-dest="${LATEST_DIR}" "${LATEST_DIR}/" "${SNAP}/"
  else
    log "Snapshot ${STAMP} déjà présent — ignoré"
  fi
fi

while IFS= read -r old; do
  [[ -n "${old}" ]] || continue
  log "Suppression snapshot expiré : ${old}"
  rm -rf "${old}"
done < <(find "${MONGO_BACKUP_DIR}/snapshots" -mindepth 1 -maxdepth 1 -type d -mtime "+${MONGO_BACKUP_RETENTION_DAYS}" 2>/dev/null || true)

USED="$(du -sh "${MONGO_BACKUP_DIR}" 2>/dev/null | awk '{print $1}')"
log "Backup OK — ${USED} dans ${MONGO_BACKUP_DIR} (rétention ${MONGO_BACKUP_RETENTION_DAYS}j)"
log "Restore smoke (staging) : sudo ${SCRIPT_DIR}/restore-mongodb.sh ${LATEST_DIR}"
