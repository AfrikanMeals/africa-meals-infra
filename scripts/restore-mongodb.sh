# Restauration d’un dump produit par backup-mongodb.sh (smoke test / DR).
# Usage (root) :
#   sudo ./scripts/restore-mongodb.sh
#   sudo ./scripts/restore-mongodb.sh /var/backups/wise-eat-mongodb/latest
#   sudo ./scripts/restore-mongodb.sh /var/backups/wise-eat-mongodb/snapshots/2026-07-12
#
# ATTENTION : écrase la base applicative sur le replica set. À utiliser sur
# un environnement de staging ou après validation explicite.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

[[ -f "${MONGODB_ENV}" ]] || die "Fichier absent : ${MONGODB_ENV} — lancer sudo ./install.sh mongodb"
set -a && source "${MONGODB_ENV}" && set +a

: "${MONGO_ROOT_USER:?MONGO_ROOT_USER manquant}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD manquant}"

DUMP_SRC="${1:-${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}/latest}"
APP_DB="${MONGO_APP_DATABASE:-wise_eat_db}"

[[ -d "${DUMP_SRC}" ]] || die "Dump introuvable : ${DUMP_SRC}"
if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-mongo-1$'; then
  die "Conteneur wise-eat-mongo-1 arrêté — impossible de restaurer"
fi

log "Restauration → db=${APP_DB} depuis ${DUMP_SRC}"
RESTORE_IN_CONTAINER="/data/db/.restore-staging"
docker exec wise-eat-mongo-1 rm -rf "${RESTORE_IN_CONTAINER}" 2>/dev/null || true
docker cp "${DUMP_SRC}/." "wise-eat-mongo-1:${RESTORE_IN_CONTAINER}/"

# mongorestore attend le dossier contenant le nom de db (…/wise_eat_db/*.bson.gz)
RESTORE_PATH="${RESTORE_IN_CONTAINER}"
if [[ -d "${DUMP_SRC}/${APP_DB}" ]] || docker exec wise-eat-mongo-1 test -d "${RESTORE_IN_CONTAINER}/${APP_DB}"; then
  RESTORE_PATH="${RESTORE_IN_CONTAINER}/${APP_DB}"
fi

docker exec wise-eat-mongo-1 mongorestore \
  --username="${MONGO_ROOT_USER}" \
  --password="${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase=admin \
  --gzip \
  --drop \
  --db="${APP_DB}" \
  "${RESTORE_PATH}"

docker exec wise-eat-mongo-1 rm -rf "${RESTORE_IN_CONTAINER}" 2>/dev/null || true
log "Restore OK — vérifier l’app (health, login, listPendingOrders)"
