#!/usr/bin/env bash
# Répare / termine l'init replica set MongoDB (rs0) après install bloqué.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component mongodb
cd "${MONGODB_DIR}"

[[ -f .env.mongodb ]] || die ".env.mongodb absent — sudo ./install.sh mongodb"

if grep -qE '^MONGO_BACKUP_CRON=30 3' .env.mongodb 2>/dev/null; then
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' .env.mongodb
fi

set -a && source .env.mongodb && set +a
MONGO_REPLICA_SET="${MONGO_REPLICA_SET:-rs0}"

mongosh_local() {
  docker exec wise-eat-mongo-1 mongosh --quiet "$@"
}

mongosh_admin() {
  docker exec wise-eat-mongo-1 mongosh \
    -u "${MONGO_ROOT_USER}" \
    -p "${MONGO_ROOT_PASSWORD}" \
    --authenticationDatabase admin \
    --quiet "$@"
}

mongosh_any() {
  if mongosh_admin --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; then
    mongosh_admin "$@"
  else
    mongosh_local "$@"
  fi
}

rs_has_primary() {
  mongosh_any --eval "
    try {
      const s = rs.status();
      print(s.members.some(m => m.stateStr === 'PRIMARY') ? 'yes' : 'no');
    } catch (e) { print('no'); }
  " 2>/dev/null | tail -n 1
}

rs_is_initiated() {
  mongosh_any --eval "
    try { rs.status(); print('yes'); }
    catch (e) { print('no'); }
  " 2>/dev/null | tail -n 1
}

log "=== Réparation replica set MongoDB (${MONGO_REPLICA_SET}) ==="

for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
    log "Démarrage stack MongoDB…"
    docker compose --env-file .env.mongodb up -d
    break
  fi
done

log "Attente ping 3/3…"
ready=0
for i in $(seq 1 90); do
  ready=0
  for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3; do
    docker exec "${name}" mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1 && ready=$((ready + 1))
  done
  [[ "${ready}" -eq 3 ]] && break
  if (( i % 10 == 0 )); then
    log "… ${ready}/3 nœuds prêts (${i}/90)"
  fi
  sleep 2
done
[[ "${ready}" -eq 3 ]] || die "3 nœuds non prêts — docker logs wise-eat-mongo-2 wise-eat-mongo-3"

initiated="$(rs_is_initiated || echo no)"
primary="$(rs_has_primary || echo no)"

log "État actuel : initiated=${initiated} primary=${primary}"

if [[ "${initiated}" != *"yes"* ]] || [[ "${primary}" != *"yes"* ]]; then
  log "rs.initiate(${MONGO_REPLICA_SET}) — majorité 2/3 requise…"
  out="$(timeout 120 mongosh_any --eval "
    try {
      const st = rs.status();
      if (st.members.some(m => m.stateStr === 'PRIMARY')) {
        print('already_primary');
        quit(0);
      }
    } catch (e) {}
    const res = rs.initiate({
      _id: '${MONGO_REPLICA_SET}',
      members: [
        { _id: 0, host: 'wise-eat-mongo-1:27017', priority: 2 },
        { _id: 1, host: 'wise-eat-mongo-2:27017', priority: 1 },
        { _id: 2, host: 'wise-eat-mongo-3:27017', priority: 1 }
      ]
    });
    printjson(res);
  " 2>&1)" || {
    echo "${out}" | sed 's/^/[wise-eat]   /'
    die "rs.initiate() échoué"
  }
  echo "${out}" | sed 's/^/[wise-eat]   /'
fi

log "Attente PRIMARY (max 3 min)…"
state=WAIT
for i in $(seq 1 90); do
  primary="$(rs_has_primary || echo no)"
  if [[ "${primary}" == *"yes"* ]]; then
    state=PRIMARY
    log "OK  PRIMARY élu (~$((i * 2))s)"
    break
  fi
  if (( i % 10 == 0 )); then
    mongosh_any --eval "
      try {
        rs.status().members.forEach(m => print(m.name + ' ' + m.stateStr));
      } catch(e) { print('rs.status: ' + e.message); }
    " 2>/dev/null | sed 's/^/[wise-eat]   /' || true
  fi
  sleep 2
done
[[ "${state}" == "PRIMARY" ]] || die "PRIMARY absent après 3 min — relancer après docker logs wise-eat-mongo-1"

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
" 2>/dev/null || warn "Utilisateur applicatif — créer manuellement si besoin"

log "Recréation mongo-express…"
docker compose --env-file .env.mongodb up -d --force-recreate mongo-express

log "Terminé — rs.status() :"
mongosh_admin --eval "rs.status().members.forEach(m => print(m.name + ' ' + m.stateStr))" 2>/dev/null \
  | sed 's/^/[wise-eat]   /'
