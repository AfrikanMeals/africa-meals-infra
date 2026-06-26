#!/usr/bin/env bash
# Installe le cron de sauvegarde MongoDB (dump quotidien + snapshot hebdo).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

MONGO_BACKUP_CRON="${MONGO_BACKUP_CRON:-30 3 * * *}"
MONGO_BACKUP_DIR="${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}"
CRON_FILE="/etc/cron.d/wise-eat-mongodb-backup"
LOG_FILE="/var/log/wise-eat-mongodb-backup.log"
BACKUP_SCRIPT="${INFRA_ROOT}/scripts/backup-mongodb.sh"

[[ -x "${BACKUP_SCRIPT}" ]] || chmod +x "${BACKUP_SCRIPT}"

mkdir -p "${MONGO_BACKUP_DIR}"
chmod 700 "${MONGO_BACKUP_DIR}"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

cat > "${CRON_FILE}" <<EOF
# Wise Eat — sauvegarde MongoDB (dump quotidien override + snapshot hebdo hardlinks)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${MONGO_BACKUP_CRON} root ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1
EOF
chmod 644 "${CRON_FILE}"

log "Cron installé : ${CRON_FILE}"
log "  Plan : ${MONGO_BACKUP_CRON} (dump quotidien, snapshot dimanche)"
log "  Destination : ${MONGO_BACKUP_DIR}"
log "  Logs : ${LOG_FILE}"
log "Test manuel : sudo ${BACKUP_SCRIPT}"
