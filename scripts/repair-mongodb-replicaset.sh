#!/usr/bin/env bash
# Répare / termine l'init replica set MongoDB (rs0) après install bloqué.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
cd "${MONGODB_DIR}"

[[ -f .env.mongodb ]] || die ".env.mongodb absent — sudo ./install.sh mongodb"

if grep -qE '^MONGO_BACKUP_CRON=30 3' .env.mongodb 2>/dev/null; then
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' .env.mongodb
fi

set -a && source .env.mongodb && set +a
MONGO_REPLICA_SET="${MONGO_REPLICA_SET:-rs0}"

mongosh_admin() {
  docker exec wise-eat-mongo-1 mongosh \
    -u "${MONGO_ROOT_USER}" \
    -p "${MONGO_ROOT_PASSWORD}" \
    --authenticationDatabase admin \
    --quiet "$@"
}

log "=== Réparation replica set MongoDB (${MONGO_REPLICA_SET}) ==="

for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
    die "Conteneur ${name} arrêté — sudo ./install.sh mongodb"
  fi
done

log "Attente ping 3/3…"
for i in $(seq 1 60); do
  ready=0
  for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3; do
    docker exec "${name}" mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1 && ready=$((ready + 1))
  done
  [[ "${ready}" -eq 3 ]] && break
  sleep 2
done
[[ "${ready:-0}" -eq 3 ]] || die "3 nœuds non prêts — docker logs wise-eat-mongo-2 wise-eat-mongo-3"

status="$(mongosh_admin --eval "
  try { printjson(rs.status().members.map(m => ({host:m.name,state:m.stateStr}))); }
  catch(e) { print('NOT_INITIATED'); }
" 2>/dev/null || echo NOT_INITIATED)"

if [[ "${status}" == *"NOT_INITIATED"* ]]; then
  log "rs.initiate()…"
  timeout 120 mongosh_admin --eval "
    rs.initiate({
      _id: '${MONGO_REPLICA_SET}',
      members: [
        { _id: 0, host: 'wise-eat-mongo-1:27017', priority: 2 },
        { _id: 1, host: 'wise-eat-mongo-2:27017', priority: 1 },
        { _id: 2, host: 'wise-eat-mongo-3:27017', priority: 1 }
      ]
    });
  " || die "rs.initiate() échoué"
else
  log "Replica set déjà initié :"
  echo "${status}" | sed 's/^/[wise-eat]   /'
fi

log "Attente PRIMARY…"
for i in $(seq 1 60); do
  state="$(mongosh_admin --eval "
    const s = rs.status();
    print(s.members.some(m => m.stateStr === 'PRIMARY') ? 'PRIMARY' : 'WAIT');
  " 2>/dev/null || echo WAIT)"
  if [[ "${state}" == "PRIMARY" ]]; then
    log "OK  PRIMARY élu"
    break
  fi
  sleep 2
done
[[ "${state:-}" == "PRIMARY" ]] || die "PRIMARY absent — rs.status() ci-dessus"

mongosh_admin --eval "
  const dbName = '${MONGO_APP_DATABASE}';
  const user = '${MONGO_APP_USER}';
  const pwd = '${MONGO_APP_PASSWORD}';
  const admin = db.getSiblingDB('admin');
  const users = (admin.getUsers().users || []).map(u => u.user);
  if (!users.includes(user)) {
    admin.createUser({
      user: user, pwd: pwd,
      roles: [{ role: 'readWrite', db: dbName }, { role: 'dbAdmin', db: dbName }]
    });
    print('app_user_created');
  } else {
    admin.updateUser(user, {
      pwd: pwd,
      roles: [{ role: 'readWrite', db: dbName }, { role: 'dbAdmin', db: dbName }]
    });
    print('app_user_updated');
  }
"

docker compose --env-file .env.mongodb up -d mongo-express 2>/dev/null || true
log "Terminé — rs.status() :"
mongosh_admin --eval "rs.status().members.forEach(m => print(m.name + ' ' + m.stateStr))"
