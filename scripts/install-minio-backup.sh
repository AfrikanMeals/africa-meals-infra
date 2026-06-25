#!/usr/bin/env bash
# Installe le cron de sauvegarde incrémentale MinIO.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

MINIO_BACKUP_CRON="${MINIO_BACKUP_CRON:-0 3 * * *}"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio}"
CRON_FILE="/etc/cron.d/wise-eat-minio-backup"
LOG_FILE="/var/log/wise-eat-minio-backup.log"
BACKUP_SCRIPT="${INFRA_ROOT}/scripts/backup-minio.sh"

[[ -x "${BACKUP_SCRIPT}" ]] || chmod +x "${BACKUP_SCRIPT}"

mkdir -p "${MINIO_BACKUP_DIR}"
chmod 700 "${MINIO_BACKUP_DIR}"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

cat > "${CRON_FILE}" <<EOF
# Wise Eat — sauvegarde incrémentale MinIO (mc mirror + snapshot hebdo)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${MINIO_BACKUP_CRON} root ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1
EOF
chmod 644 "${CRON_FILE}"

log "Cron installé : ${CRON_FILE}"
log "  Plan : ${MINIO_BACKUP_CRON} (mirror quotidien, snapshot dimanche)"
log "  Destination : ${MINIO_BACKUP_DIR}"
log "  Logs : ${LOG_FILE}"
log "Test manuel : sudo ${BACKUP_SCRIPT}"
