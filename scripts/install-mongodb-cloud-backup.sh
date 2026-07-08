#!/usr/bin/env bash
# Installe le cron d'upload hebdomadaire MongoDB → GCS / Firebase Storage / AWS S3.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

if [[ -f "${MONGODB_ENV}" ]]; then
  set -a && source "${MONGODB_ENV}" && set +a
fi

MONGO_CLOUD_BACKUP_CRON="${MONGO_CLOUD_BACKUP_CRON:-0 4 * * 0}"
CRON_FILE="/etc/cron.d/wise-eat-mongodb-cloud-backup"
LOG_FILE="/var/log/wise-eat-mongodb-cloud-backup.log"
UPLOAD_SCRIPT="${INFRA_ROOT}/scripts/upload-mongodb-cloud-backup.sh"

[[ -x "${UPLOAD_SCRIPT}" ]] || chmod +x "${UPLOAD_SCRIPT}"

touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

cat > "${CRON_FILE}" <<EOF
# Wise Eat — upload hebdo MongoDB off-site (Backup_DB_1 … Backup_DB_4, écrase chaque mois)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${MONGO_CLOUD_BACKUP_CRON} root ${UPLOAD_SCRIPT} >> ${LOG_FILE} 2>&1
EOF
chmod 644 "${CRON_FILE}"

log "Cron cloud installé : ${CRON_FILE}"
log "  Plan : ${MONGO_CLOUD_BACKUP_CRON} (dimanche 04:00 par défaut, après dump local 03:30)"
log "  Rotation : Backup_DB_1 (j1-7) … Backup_DB_4 (j22+) — écrasement mensuel"
log "  Logs : ${LOG_FILE}"
log ""
log "Credentials cloud : ${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}"
log "  (GCS_BUCKET, AM_FIREBASE_STORAGE_BUCKET, AWS_S3_BUCKET, AWS_*, accounts.json)"
log ""
log "Prérequis sur le VPS :"
log "  • gcloud ou gsutil (GCS / Firebase Storage)"
log "  • aws CLI (S3)"
log ""
log "Test manuel :"
log "  sudo ./scripts/mongodb-backup.sh env-check"
log "  sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud-dry-run"
log "  sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud"
log "Docs : docs/MONGODB_BACKUP.md · docs/MONGODB_BACKUP.html"
