#!/usr/bin/env bash
# Renomme la base applicative MongoDB (ex. african_meals_db → wise_eat_db).
# Met à jour .env.mongodb, droits wise-eat-app, copie optionnelle des données.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

OLD_DB="${MONGO_APP_DATABASE_OLD:-african_meals_db}"
NEW_DB="${MONGO_APP_DATABASE_NEW:-wise_eat_db}"
COPY_DATA="${MONGO_RENAME_COPY_DATA:-1}"

[[ -f "${MONGODB_ENV}" ]] || die "Fichier absent : ${MONGODB_ENV}"

set -a && source "${MONGODB_ENV}" && set +a
: "${MONGO_ROOT_USER:?MONGO_ROOT_USER manquant}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD manquant}"
: "${MONGO_APP_USER:?MONGO_APP_USER manquant}"
: "${MONGO_APP_PASSWORD:?MONGO_APP_PASSWORD manquant}"

CURRENT_DB="${MONGO_APP_DATABASE:-african_meals_db}"
if [[ -n "${MONGO_APP_DATABASE_NEW:-}" ]]; then
  NEW_DB="${MONGO_APP_DATABASE_NEW}"
fi

if [[ "${CURRENT_DB}" == "${NEW_DB}" && "${OLD_DB}" == "${NEW_DB}" ]]; then
  log "MONGO_APP_DATABASE déjà ${NEW_DB}"
else
  log "Mise à jour ${MONGODB_ENV} : MONGO_APP_DATABASE=${NEW_DB}"
  if grep -q '^MONGO_APP_DATABASE=' "${MONGODB_ENV}"; then
    sed -i "s/^MONGO_APP_DATABASE=.*/MONGO_APP_DATABASE=${NEW_DB}/" "${MONGODB_ENV}"
  else
    echo "MONGO_APP_DATABASE=${NEW_DB}" >> "${MONGODB_ENV}"
  fi
fi

log "=== Droits ${MONGO_APP_USER} sur ${NEW_DB} ==="
docker exec wise-eat-mongo-1 mongosh \
  -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase admin --quiet --eval "
    const user = '${MONGO_APP_USER}';
    const pwd = '${MONGO_APP_PASSWORD}';
    const dbName = '${NEW_DB}';
    const admin = db.getSiblingDB('admin');
    const roles = [
      { role: 'readWrite', db: dbName },
      { role: 'dbAdmin', db: dbName },
    ];
    const users = admin.getUsers().users.map((u) => u.user);
    if (!users.includes(user)) {
      admin.createUser({ user, pwd, roles });
      print('app_user_created');
    } else {
      const existing = admin.getUser(user).roles || [];
      const merged = [...existing];
      for (const r of roles) {
        if (!merged.some((x) => x.role === r.role && x.db === r.db)) merged.push(r);
      }
      admin.updateUser(user, { pwd, roles: merged });
      print('app_user_updated');
    }
    db.getSiblingDB(dbName).createCollection('_init', { capped: false });
  "

if [[ "${COPY_DATA}" == "1" && "${OLD_DB}" != "${NEW_DB}" ]]; then
  log "=== Copie ${OLD_DB} → ${NEW_DB} (mongodump | mongorestore) ==="
  docker exec wise-eat-mongo-1 mongosh --quiet --eval "
    const n = db.getSiblingDB('${OLD_DB}').getCollectionNames().filter(
      (c) => !c.startsWith('system.')
    ).length;
    print(n);
  " | grep -q '^0$' && log "Ancienne base ${OLD_DB} vide — copie ignorée" || true

  docker exec wise-eat-mongo-1 mongodump \
    --username="${MONGO_ROOT_USER}" \
    --password="${MONGO_ROOT_PASSWORD}" \
    --authenticationDatabase=admin \
    --db="${OLD_DB}" \
    --archive="/data/db/.rename-staging.dump" \
    --gzip 2>/dev/null || die "mongodump ${OLD_DB} échoué"

  docker exec wise-eat-mongo-1 mongorestore \
    --username="${MONGO_ROOT_USER}" \
    --password="${MONGO_ROOT_PASSWORD}" \
    --authenticationDatabase=admin \
    --nsFrom="${OLD_DB}.*" \
    --nsTo="${NEW_DB}.*" \
    --drop \
    --gzip \
    --archive="/data/db/.rename-staging.dump" 2>/dev/null \
    || die "mongorestore vers ${NEW_DB} échoué"

  docker exec wise-eat-mongo-1 rm -f /data/db/.rename-staging.dump 2>/dev/null || true
  log "Copie terminée : ${OLD_DB} → ${NEW_DB}"
fi

log "=== URI applicative ==="
log "LOCAL  : mongodb://${MONGO_APP_USER}:****@127.0.0.1:27017/${NEW_DB}?authSource=admin&replicaSet=${MONGO_REPLICA_SET:-rs0}"
log "REMOTE : mongodb://${MONGO_APP_USER}:****@${MONGO_TLS_DOMAIN:-db.wise-eat.com}:${MONGO_TLS_PORT:-27018}/${NEW_DB}?authSource=admin&tls=true&directConnection=true"
log "Test : docker exec wise-eat-mongo-1 mongosh -u ${MONGO_APP_USER} -p '***' --authenticationDatabase admin --eval 'db.getSiblingDB(\"${NEW_DB}\").stats()'"
