#!/usr/bin/env bash
# Wise Eat — CLI sauvegarde MongoDB (local quotidien + cloud hebdo).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Wise Eat — sauvegarde MongoDB

Usage:
  sudo ./scripts/mongodb-backup.sh <commande> [options]

Commandes:
  local              Dump local (mongodump → /var/backups/wise-eat-mongodb)
  cloud              Upload hebdo cloud (GCS + Firebase + AWS, rotation Backup_DB_1…4)
  cloud-dry-run      Simule l'upload cloud sans envoi
  install-local      Installe cron dump quotidien (03:30)
  install-cloud      Installe cron upload cloud (dimanche 04:00)
  install-all        install-local + install-cloud
  status             État backups locaux, crons et config cloud (.env.prod)
  env-check          Affiche URIs / credentials résolus depuis .env.prod
  preflight          Test CLI + credentials + écriture 1 octet par destination
  verify-aws         Diagnostic AWS S3 (.env.prod — signature, horloge, ls/cp)
  install-cloud-tools Installe gcloud + aws CLI sur le VPS
  self-test          Tests unitaires (slot semaine)
  restore-help       Aide restauration depuis archive cloud ou local

Variables:
  MONGO_CLOUD_API_ENV=/opt/wise-eat-api/.env.prod   credentials cloud (buckets, AWS, Google SA)
  MONGO_CLOUD_BACKUP_FORCE=1                        forcer upload cloud hors dimanche
  MONGO_CLOUD_BACKUP_DRY_RUN=1                      simulation (cloud / cloud-dry-run)

Docs:
  docs/MONGODB_BACKUP.md · docs/MONGODB_BACKUP.html

Exemples:
  sudo ./scripts/mongodb-backup.sh local
  sudo ./scripts/mongodb-backup.sh env-check
  sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud
  sudo ./scripts/mongodb-backup.sh install-all
EOF
}

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Exécuter en root : sudo $0 $*"
  fi
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  local|dump)
    require_sudo
    exec bash "${SCRIPT_DIR}/backup-mongodb.sh"
    ;;
  cloud|upload)
    require_sudo
    export MONGO_CLOUD_BACKUP_FORCE="${MONGO_CLOUD_BACKUP_FORCE:-0}"
    exec bash "${SCRIPT_DIR}/upload-mongodb-cloud-backup.sh"
    ;;
  cloud-dry-run)
    require_sudo
    export MONGO_CLOUD_BACKUP_FORCE="${MONGO_CLOUD_BACKUP_FORCE:-1}"
    export MONGO_CLOUD_BACKUP_DRY_RUN=1
    exec bash "${SCRIPT_DIR}/upload-mongodb-cloud-backup.sh"
    ;;
  install-local)
    require_sudo
    exec bash "${SCRIPT_DIR}/install-mongodb-backup.sh"
    ;;
  install-cloud)
    require_sudo
    exec bash "${SCRIPT_DIR}/install-mongodb-cloud-backup.sh"
    ;;
  install-all)
    require_sudo
    bash "${SCRIPT_DIR}/install-mongodb-backup.sh"
    bash "${SCRIPT_DIR}/install-mongodb-cloud-backup.sh"
    ;;
  self-test)
    exec bash "${SCRIPT_DIR}/upload-mongodb-cloud-backup.sh" --self-test
    ;;
  env-check)
    [[ -f "${MONGODB_ENV}" ]] || die "Absent : ${MONGODB_ENV}"
    set -a && source "${MONGODB_ENV}" && set +a
    # shellcheck source=lib/mongodb-cloud-backup.sh
    source "${SCRIPT_DIR}/lib/mongodb-cloud-backup.sh"
    # shellcheck source=lib/mongodb-cloud-backup-env.sh
    source "${SCRIPT_DIR}/lib/mongodb-cloud-backup-env.sh"
    mongodb_cloud_backup_apply_api_env
    mongodb_cloud_backup_print_env_summary
    ;;
  preflight)
    require_sudo
    [[ -f "${MONGODB_ENV}" ]] || die "Absent : ${MONGODB_ENV}"
    set -a && source "${MONGODB_ENV}" && set +a
    # shellcheck source=lib/mongodb-cloud-backup.sh
    source "${SCRIPT_DIR}/lib/mongodb-cloud-backup.sh"
    # shellcheck source=lib/mongodb-cloud-backup-env.sh
    source "${SCRIPT_DIR}/lib/mongodb-cloud-backup-env.sh"
    mongodb_cloud_backup_apply_api_env
    mongodb_cloud_backup_print_env_summary
    echo ""
    mongodb_cloud_backup_preflight
    ;;
  install-cloud-tools)
    require_sudo
    exec bash "${SCRIPT_DIR}/install-mongodb-cloud-tools.sh"
    ;;
  verify-aws)
    exec bash "${SCRIPT_DIR}/verify-aws-s3-env.sh" "${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}"
    ;;
  status)
    echo "=== Crons ==="
    for f in /etc/cron.d/wise-eat-mongodb-backup /etc/cron.d/wise-eat-mongodb-cloud-backup; do
      if [[ -f "${f}" ]]; then
        echo "--- ${f} ---"
        cat "${f}"
      else
        echo "Absent : ${f}"
      fi
    done
    echo ""
    echo "=== Backups locaux ==="
    local_dir="${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}"
    if [[ -d "${local_dir}" ]]; then
      du -sh "${local_dir}"/* 2>/dev/null || du -sh "${local_dir}"
      ls -la "${local_dir}/latest" 2>/dev/null | head -5 || true
      echo "Snapshots : $(find "${local_dir}/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    else
      echo "Répertoire absent : ${local_dir}"
    fi
    echo ""
    echo "=== Derniers logs ==="
    for log in /var/log/wise-eat-mongodb-backup.log /var/log/wise-eat-mongodb-cloud-backup.log; do
      if [[ -f "${log}" ]]; then
        echo "--- ${log} (5 dernières lignes) ---"
        tail -5 "${log}" 2>/dev/null || true
      fi
    done
    echo ""
    echo "=== Config cloud (.env.prod) ==="
    bash "${SCRIPT_DIR}/mongodb-backup.sh" env-check 2>/dev/null || true
    ;;
  restore-help)
    cat <<'EOF'
Restauration MongoDB Wise Eat

1) Depuis backup local (latest/) :
   sudo systemctl stop … # arrêter apps écrivant en base si besoin
   docker cp /var/backups/wise-eat-mongodb/latest/. wise-eat-mongo-1:/tmp/restore/
   docker exec wise-eat-mongo-1 mongorestore \
     --username="$MONGO_ROOT_USER" --password="$MONGO_ROOT_PASSWORD" \
     --authenticationDatabase=admin --gzip --drop /tmp/restore/

2) Depuis cloud (ex. Backup_DB_2.tar.gz sur S3) :
   aws s3 cp s3://BUCKET/mongodb/Backup_DB_2.tar.gz /tmp/
   tar -xzf /tmp/Backup_DB_2.tar.gz -C /tmp/mongo-restore/
   docker cp /tmp/mongo-restore/. wise-eat-mongo-1:/tmp/restore/
   # puis mongorestore comme ci-dessus

3) Firebase / GCS :
   gcloud storage cp gs://BUCKET/mongodb/Backup_DB_N.tar.gz /tmp/
   # idem extraction + mongorestore

Voir docs/MONGODB_BACKUP.html pour le détail et les prérequis IAM.
EOF
    ;;
  help|--help|-h|"")
    usage
    ;;
  *)
    echo "Commande inconnue : ${cmd}" >&2
    usage >&2
    exit 1
    ;;
esac
