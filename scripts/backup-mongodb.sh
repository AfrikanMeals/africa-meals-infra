#!/usr/bin/env bash
# Sauvegarde MongoDB — dump quotidien (override latest/) + snapshot hebdomadaire (hardlinks rsync).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

[[ -f "${MONGODB_ENV}" ]] || die "Fichier absent : ${MONGODB_ENV} — lancer sudo ./install.sh mongodb"

# Fix: MONGO_BACKUP_CRON non quoté cassait `source` (.env).
if grep -qE '^MONGO_BACKUP_CRON=30 3' "${MONGODB_ENV}" 2>/dev/null; then
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' "${MONGODB_ENV}"
fi

set -a && source "${MONGODB_ENV}" && set +a

: "${MONGO_ROOT_USER:?MONGO_ROOT_USER manquant}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD manquant}"

MONGO_BACKUP_DIR="${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}"
MONGO_BACKUP_RETENTION_DAYS="${MONGO_BACKUP_RETENTION_DAYS:-30}"
MONGO_BACKUP_SNAPSHOT_WEEKDAY="${MONGO_BACKUP_SNAPSHOT_WEEKDAY:-7}"
MONGO_APP_DATABASE="${MONGO_APP_DATABASE:-wise_eat_db}"
# Oplog = dump instance entière (lourd sur volume 5 Go) — off par défaut.
MONGO_BACKUP_WITH_OPLOG="${MONGO_BACKUP_WITH_OPLOG:-0}"
STAMP="$(date +%Y-%m-%d)"
STAMP_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"

mkdir -p "${MONGO_BACKUP_DIR}/latest" "${MONGO_BACKUP_DIR}/snapshots"
chmod 700 "${MONGO_BACKUP_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-mongo-1$'; then
  die "Conteneur wise-eat-mongo-1 arrêté — impossible de sauvegarder"
fi

LATEST_DIR="${MONGO_BACKUP_DIR}/latest"
STAGING="${MONGO_BACKUP_DIR}/.staging-${STAMP}"
# Fix: ne plus écrire dans /data/db (volume WiredTiger 5 Go) — dump hors data dir.
CONTAINER_DUMP="/tmp/wise-eat-mongodump-${STAMP}"

log "Dump → ${LATEST_DIR}/ (db=${MONGO_APP_DATABASE}, oplog=${MONGO_BACKUP_WITH_OPLOG})"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"

# Nettoyage staging conteneur (run précédent interrompu).
docker exec wise-eat-mongo-1 rm -rf "${CONTAINER_DUMP}" 2>/dev/null || true

# 1. Mot de passe via env conteneur (évite expansion $ / ` côté host).
# 2. Dump DB app (gzip) — fiable sans --oplog+--db (incompatible MongoDB).
dump_rc=0
if [[ "${MONGO_BACKUP_WITH_OPLOG}" == "1" ]]; then
  # Oplog : dump complet replica set (pas --db).
  docker exec \
    -e WE_MONGO_USER="${MONGO_ROOT_USER}" \
    -e WE_MONGO_PASS="${MONGO_ROOT_PASSWORD}" \
    -e WE_DUMP_OUT="${CONTAINER_DUMP}" \
    wise-eat-mongo-1 \
    bash -c 'mongodump \
      --username="$WE_MONGO_USER" \
      --password="$WE_MONGO_PASS" \
      --authenticationDatabase=admin \
      --gzip \
      --oplog \
      --out="$WE_DUMP_OUT"' || dump_rc=$?
else
  docker exec \
    -e WE_MONGO_USER="${MONGO_ROOT_USER}" \
    -e WE_MONGO_PASS="${MONGO_ROOT_PASSWORD}" \
    -e WE_MONGO_DB="${MONGO_APP_DATABASE}" \
    -e WE_DUMP_OUT="${CONTAINER_DUMP}" \
    wise-eat-mongo-1 \
    bash -c 'mongodump \
      --username="$WE_MONGO_USER" \
      --password="$WE_MONGO_PASS" \
      --authenticationDatabase=admin \
      --db="$WE_MONGO_DB" \
      --gzip \
      --out="$WE_DUMP_OUT"' || dump_rc=$?
fi

if [[ "${dump_rc}" -ne 0 ]]; then
  docker exec wise-eat-mongo-1 rm -rf "${CONTAINER_DUMP}" 2>/dev/null || true
  die "mongodump échoué (exit ${dump_rc}) — logs : docker logs wise-eat-mongo-1 | tail"
fi

docker cp "wise-eat-mongo-1:${CONTAINER_DUMP}/." "${STAGING}/"
docker exec wise-eat-mongo-1 rm -rf "${CONTAINER_DUMP}" 2>/dev/null || true

if [[ -z "$(ls -A "${STAGING}" 2>/dev/null || true)" ]]; then
  die "Dump vide — vérifier authentification et replica set"
fi

rm -rf "${LATEST_DIR:?}"/*
mv "${STAGING}"/* "${LATEST_DIR}/"
rmdir "${STAGING}" 2>/dev/null || true

# Marqueur fraîcheur pour status / cloud.
cat > "${LATEST_DIR}/.backup-ok.json" <<EOF
{"createdAt":"${STAMP_ISO}","database":"${MONGO_APP_DATABASE}","oplog":${MONGO_BACKUP_WITH_OPLOG},"host":"$(hostname -s 2>/dev/null || echo unknown)"}
EOF

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
