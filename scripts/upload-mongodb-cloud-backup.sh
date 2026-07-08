#!/usr/bin/env bash
# Upload hebdomadaire MongoDB → GCS + Firebase Storage + AWS S3.
# Archive complète (dump latest/ ou snapshot du jour), rotation Backup_DB_1 … _4.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/mongodb-cloud-backup.sh
source "${SCRIPT_DIR}/lib/mongodb-cloud-backup.sh"
# shellcheck source=lib/mongodb-cloud-backup-env.sh
source "${SCRIPT_DIR}/lib/mongodb-cloud-backup-env.sh"

if [[ "${1:-}" == "--self-test" ]]; then
  mongodb_cloud_backup_self_test
  exit $?
fi

[[ -f "${MONGODB_ENV}" ]] || die "Fichier absent : ${MONGODB_ENV} — lancer sudo ./install.sh mongodb"

set -a && source "${MONGODB_ENV}" && set +a
mongodb_cloud_backup_apply_api_env

MONGO_BACKUP_DIR="${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}"
MONGO_CLOUD_API_ENV="${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}"
MONGO_CLOUD_BACKUP_WEEKDAY="${MONGO_CLOUD_BACKUP_WEEKDAY:-7}"
MONGO_CLOUD_BACKUP_FORCE="${MONGO_CLOUD_BACKUP_FORCE:-0}"
MONGO_CLOUD_BACKUP_DRY_RUN="${MONGO_CLOUD_BACKUP_DRY_RUN:-0}"

env_truthy() {
  local raw="${1:-}"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]')"
  [[ "${raw}" == "1" || "${raw}" == "true" || "${raw}" == "yes" || "${raw}" == "on" ]]
}

if ! env_truthy "${MONGO_CLOUD_BACKUP_ENABLED:-0}"; then
  log "Cloud backup désactivé (MONGO_CLOUD_BACKUP_ENABLED=0) — sortie"
  exit 0
fi

WEEKDAY="$(date +%u)"
if [[ "${MONGO_CLOUD_BACKUP_FORCE}" != "1" ]] && [[ "${WEEKDAY}" != "${MONGO_CLOUD_BACKUP_WEEKDAY}" ]]; then
  log "Pas le jour prévu (aujourd'hui=${WEEKDAY}, attendu=${MONGO_CLOUD_BACKUP_WEEKDAY}) — sortie (MONGO_CLOUD_BACKUP_FORCE=1 pour forcer)"
  exit 0
fi

GCS_ON=0 FIREBASE_ON=0 AWS_ON=0
env_truthy "${MONGO_CLOUD_GCS_ENABLED:-0}" && GCS_ON=1
env_truthy "${MONGO_CLOUD_FIREBASE_ENABLED:-0}" && FIREBASE_ON=1
env_truthy "${MONGO_CLOUD_AWS_ENABLED:-0}" && AWS_ON=1

if [[ "${GCS_ON}" -eq 0 && "${FIREBASE_ON}" -eq 0 && "${AWS_ON}" -eq 0 ]]; then
  die "Aucune destination cloud activée — activer MONGO_CLOUD_GCS_ENABLED / FIREBASE / AWS"
fi

if [[ "${MONGO_CLOUD_BACKUP_DRY_RUN}" != "1" ]] && [[ "${MONGO_CLOUD_BACKUP_SKIP_PREFLIGHT:-0}" != "1" ]]; then
  log "Preflight cloud…"
  if ! mongodb_cloud_backup_preflight; then
    die "Preflight échoué — sudo ./scripts/mongodb-backup.sh preflight pour le détail"
  fi
fi

SOURCE_DIR="$(mongodb_cloud_backup_resolve_source_dir "${MONGO_BACKUP_DIR}")" \
  || die "Aucune sauvegarde locale dans ${MONGO_BACKUP_DIR}/latest (lancer sudo ./scripts/backup-mongodb.sh)"

SLOT="$(mongodb_cloud_backup_week_slot)"
OBJECT_NAME="$(mongodb_cloud_backup_object_name "${SLOT}")"
STAMP="$(date +%Y-%m-%dT%H:%M:%S%z)"
WORK_DIR="$(mktemp -d "${MONGO_BACKUP_DIR}/.cloud-upload-XXXXXX")"
ARCHIVE="${WORK_DIR}/${OBJECT_NAME}"
META="${WORK_DIR}/${OBJECT_NAME%.tar.gz}.meta.json"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log "Semaine ${SLOT}/4 du mois → ${OBJECT_NAME} (source : ${SOURCE_DIR})"
log "Création archive…"
mongodb_cloud_backup_create_archive "${SOURCE_DIR}" "${ARCHIVE}"
ARCHIVE_SIZE="$(du -h "${ARCHIVE}" | awk '{print $1}')"
log "Archive ${ARCHIVE_SIZE} : ${OBJECT_NAME}"

cat > "${META}" <<EOF
{"object":"${OBJECT_NAME}","weekSlot":${SLOT},"source":"${SOURCE_DIR}","createdAt":"${STAMP}","database":"${MONGO_APP_DATABASE:-wise_eat_db}"}
EOF

upload_ok=0
upload_fail=0

upload_to_gcs() {
  local label="$1" uri="$2" creds="${3:-}"
  local dest meta_dest

  [[ -n "${uri}" ]] || die "${label} : URI manquante"
  dest="$(mongodb_cloud_backup_uri_join "${uri}" "${OBJECT_NAME}")"
  meta_dest="$(mongodb_cloud_backup_uri_join "${uri}" "$(basename "${META}")")"

  if [[ "${MONGO_CLOUD_BACKUP_DRY_RUN}" == "1" ]]; then
    log "[dry-run] ${label} → ${dest}"
    return 0
  fi

  log "${label} → ${dest} (écrase l'archive du même slot)"
  if ! mongodb_cloud_backup_run_gs_upload "${dest}" "${ARCHIVE}" "${creds}"; then
    warn "${label} upload échoué : ${MONGODB_CLOUD_LAST_ERROR}"
    return 1
  fi
  mongodb_cloud_backup_run_gs_upload "${meta_dest}" "${META}" "${creds}" \
    || warn "${label} : métadonnées non uploadées (${meta_dest})"
  return 0
}

upload_to_aws() {
  local uri="${MONGO_CLOUD_AWS_URI:-}"
  local region="${MONGO_CLOUD_AWS_REGION:-}"
  local dest meta_dest

  [[ -n "${uri}" ]] || die "AWS : MONGO_CLOUD_AWS_URI manquante"
  dest="$(mongodb_cloud_backup_uri_join "${uri}" "${OBJECT_NAME}")"
  meta_dest="$(mongodb_cloud_backup_uri_join "${uri}" "$(basename "${META}")")"

  if [[ -n "${MONGO_CLOUD_AWS_ACCESS_KEY_ID:-}" ]]; then
    export AWS_ACCESS_KEY_ID="${MONGO_CLOUD_AWS_ACCESS_KEY_ID}"
  fi
  if [[ -n "${MONGO_CLOUD_AWS_SECRET_ACCESS_KEY:-}" ]]; then
    export AWS_SECRET_ACCESS_KEY="${MONGO_CLOUD_AWS_SECRET_ACCESS_KEY}"
  fi
  if [[ -n "${MONGO_CLOUD_AWS_SESSION_TOKEN:-}" ]]; then
    export AWS_SESSION_TOKEN="${MONGO_CLOUD_AWS_SESSION_TOKEN}"
  fi

  if [[ "${MONGO_CLOUD_BACKUP_DRY_RUN}" == "1" ]]; then
    log "[dry-run] AWS S3 → ${dest}"
    return 0
  fi

  log "AWS S3 → ${dest} (écrase l'archive du même slot)"
  if ! mongodb_cloud_backup_run_aws_upload "${dest}" "${ARCHIVE}" "${region}"; then
    warn "AWS S3 upload échoué : ${MONGODB_CLOUD_LAST_ERROR}"
    return 1
  fi
  mongodb_cloud_backup_run_aws_upload "${meta_dest}" "${META}" "${region}" \
    || warn "AWS : métadonnées non uploadées (${meta_dest})"
  return 0
}

GCS_CREDS="${MONGO_CLOUD_GCS_CREDENTIALS:-}"
FIREBASE_CREDS="${MONGO_CLOUD_FIREBASE_CREDENTIALS:-${GCS_CREDS}}"

log "Credentials API : ${MONGO_CLOUD_API_ENV}"

if [[ "${GCS_ON}" -eq 1 ]]; then
  if upload_to_gcs "GCS" "${MONGO_CLOUD_GCS_URI:-}" "${GCS_CREDS}"; then
    upload_ok=$((upload_ok + 1))
  else
    upload_fail=$((upload_fail + 1))
  fi
fi

if [[ "${FIREBASE_ON}" -eq 1 ]]; then
  if upload_to_gcs "Firebase Storage" "${MONGO_CLOUD_FIREBASE_URI:-}" "${FIREBASE_CREDS}"; then
    upload_ok=$((upload_ok + 1))
  else
    upload_fail=$((upload_fail + 1))
  fi
fi

if [[ "${AWS_ON}" -eq 1 ]]; then
  if upload_to_aws; then
    upload_ok=$((upload_ok + 1))
  else
    upload_fail=$((upload_fail + 1))
  fi
fi

if [[ "${upload_fail}" -gt 0 ]]; then
  die "Upload cloud partiel — ${upload_ok} OK, ${upload_fail} échec(s)"
fi

log "Upload cloud OK — ${OBJECT_NAME} (${ARCHIVE_SIZE}) vers ${upload_ok} destination(s)"
