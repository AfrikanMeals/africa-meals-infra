#!/usr/bin/env bash
# Sauvegarde incrémentale MinIO — mc mirror vers /var/backups/wise-eat-minio.
# Plan : mirror quotidien (delta) + snapshot hebdomadaire (hardlinks rsync).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

[[ -f "${MINIO_ENV}" ]] || die "Fichier absent : ${MINIO_ENV} — lancer sudo ./install.sh minio"

set -a && source "${MINIO_ENV}" && set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER manquant}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD manquant}"

MINIO_BUCKET="${MINIO_BUCKET:-wise-eat}"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio}"
MINIO_BACKUP_RETENTION_DAYS="${MINIO_BACKUP_RETENTION_DAYS:-30}"
MINIO_BACKUP_SNAPSHOT_WEEKDAY="${MINIO_BACKUP_SNAPSHOT_WEEKDAY:-7}"
STAMP="$(date +%Y-%m-%d)"
MC_IMAGE="${MINIO_MC_IMAGE:-minio/mc:RELEASE.2024-10-08T09-37-26Z}"

mkdir -p "${MINIO_BACKUP_DIR}/latest" "${MINIO_BACKUP_DIR}/snapshots"
chmod 700 "${MINIO_BACKUP_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-minio$'; then
  die "Conteneur wise-eat-minio arrêté — impossible de sauvegarder"
fi

log "Mirror incrémental ${MINIO_BUCKET} → ${MINIO_BACKUP_DIR}/latest/"
docker run --rm --network wise-eat-minio \
  -v "${MINIO_BACKUP_DIR}:/backup:rw" \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  -e MINIO_BUCKET \
  "${MC_IMAGE}" \
  /bin/sh -c '
    set -e
    mc alias set local http://minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
    mc mirror --overwrite --remove "local/${MINIO_BUCKET}" "/backup/latest/${MINIO_BUCKET}"
  '

LATEST="${MINIO_BACKUP_DIR}/latest/${MINIO_BUCKET}"
if [[ ! -d "${LATEST}" ]]; then
  die "Mirror vide — vérifier bucket ${MINIO_BUCKET}"
fi

WEEKDAY="$(date +%u)"
if [[ "${WEEKDAY}" == "${MINIO_BACKUP_SNAPSHOT_WEEKDAY}" ]]; then
  SNAP="${MINIO_BACKUP_DIR}/snapshots/${STAMP}/${MINIO_BUCKET}"
  if [[ ! -d "${SNAP}" ]]; then
    log "Snapshot hebdomadaire (hardlinks) → ${SNAP}"
    mkdir -p "${MINIO_BACKUP_DIR}/snapshots/${STAMP}"
    rsync -a --delete --link-dest="${LATEST}" "${LATEST}/" "${SNAP}/"
  else
    log "Snapshot ${STAMP} déjà présent — ignoré"
  fi
fi

while IFS= read -r old; do
  [[ -n "${old}" ]] || continue
  log "Suppression snapshot expiré : ${old}"
  rm -rf "${old}"
done < <(find "${MINIO_BACKUP_DIR}/snapshots" -mindepth 1 -maxdepth 1 -type d -mtime "+${MINIO_BACKUP_RETENTION_DAYS}" 2>/dev/null || true)

USED="$(du -sh "${MINIO_BACKUP_DIR}" 2>/dev/null | awk '{print $1}')"
log "Backup OK — ${USED} dans ${MINIO_BACKUP_DIR} (rétention ${MINIO_BACKUP_RETENTION_DAYS}j)"
