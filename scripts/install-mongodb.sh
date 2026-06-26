#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/mongodb-storage.sh
source "${SCRIPT_DIR}/lib/mongodb-storage.sh"

require_root
sync_component mongodb
cd "${MONGODB_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.mongodb ]]; then
  log "Création .env.mongodb (mots de passe aléatoires)"
  MONGO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  MONGO_APP_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  MONGO_ADMIN_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  cp .env.example .env.mongodb
  sed -i "s|^MONGO_ROOT_PASSWORD=.*|MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}|" .env.mongodb
  sed -i "s|^MONGO_APP_PASSWORD=.*|MONGO_APP_PASSWORD=${MONGO_APP_PASSWORD}|" .env.mongodb
  sed -i "s|^MONGO_ADMIN_BASIC_AUTH_PASSWORD=.*|MONGO_ADMIN_BASIC_AUTH_PASSWORD=${MONGO_ADMIN_BASIC_AUTH_PASSWORD}|" .env.mongodb
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' .env.mongodb
  chmod 600 .env.mongodb
  log "Mots de passe enregistrés dans ${MONGODB_DIR}/.env.mongodb"
fi

if ! grep -q '^MONGO_ADMIN_BASIC_AUTH_PASSWORD=.' .env.mongodb 2>/dev/null; then
  MONGO_ADMIN_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  if grep -q '^MONGO_ADMIN_BASIC_AUTH_PASSWORD=' .env.mongodb; then
    sed -i "s|^MONGO_ADMIN_BASIC_AUTH_PASSWORD=.*|MONGO_ADMIN_BASIC_AUTH_PASSWORD=${MONGO_ADMIN_BASIC_AUTH_PASSWORD}|" .env.mongodb
  else
    echo "MONGO_ADMIN_BASIC_AUTH_PASSWORD=${MONGO_ADMIN_BASIC_AUTH_PASSWORD}" >> .env.mongodb
  fi
  log "Mot de passe basic auth admin MongoDB généré → .env.mongodb"
fi

# Cron avec espaces — doit être quoté pour « source .env.mongodb »
if grep -qE '^MONGO_BACKUP_CRON=30 3' .env.mongodb 2>/dev/null; then
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' .env.mongodb
fi

set -a && source .env.mongodb && set +a

: "${MONGO_ROOT_USER:?MONGO_ROOT_USER manquant}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD manquant}"
: "${MONGO_APP_USER:?MONGO_APP_USER manquant}"
: "${MONGO_APP_PASSWORD:?MONGO_APP_PASSWORD manquant}"
: "${MONGO_APP_DATABASE:?MONGO_APP_DATABASE manquant}"

MONGO_REPLICA_SET="${MONGO_REPLICA_SET:-rs0}"
MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
MONGO_ADMIN_DOMAIN="${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"

ensure_mongodb_swap
ensure_mongodb_data_volume
persist_mongodb_env_paths
set -a && source .env.mongodb && set +a

if [[ ! -f keyfile ]]; then
  log "Génération keyfile replica set (auth inter-nœuds)"
  openssl rand -base64 756 > keyfile
  chmod 400 keyfile
  chown 999:999 keyfile
fi

mkdir -p "${MONGO_DATA_1}" "${MONGO_DATA_2}" "${MONGO_DATA_3}"
chown -R 999:999 "${MONGO_DATA_1}" "${MONGO_DATA_2}" "${MONGO_DATA_3}" keyfile

log "Démarrage MongoDB Docker (replica set ${MONGO_REPLICA_SET})"
docker compose --env-file .env.mongodb pull
docker compose --env-file .env.mongodb up -d

wait_for_mongo_primary() {
  local max="${1:-90}"
  for i in $(seq 1 "$max"); do
    if docker exec wise-eat-mongo-1 mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_mongo_cluster() {
  local max="${1:-90}"
  local name ready
  log "Attente des 3 nœuds MongoDB (ping)…"
  for i in $(seq 1 "$max"); do
    ready=0
    for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3; do
      if docker exec "${name}" mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; then
        ready=$((ready + 1))
      fi
    done
    if [[ "${ready}" -eq 3 ]]; then
      log "OK  3/3 nœuds MongoDB répondent (~$((i * 2))s)"
      return 0
    fi
    if (( i % 5 == 0 )); then
      log "… attente nœuds ${i}/${max} (${ready}/3 prêts)"
    fi
    sleep 2
  done
  warn "Tous les nœuds ne répondent pas — diagnostic :"
  for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3; do
    docker logs --tail=15 "${name}" 2>&1 | sed "s/^/[wise-eat]   ${name}: /" || true
  done
  return 1
}

mongosh_admin() {
  docker exec wise-eat-mongo-1 mongosh \
    -u "${MONGO_ROOT_USER}" \
    -p "${MONGO_ROOT_PASSWORD}" \
    --authenticationDatabase admin \
    --quiet "$@"
}

init_replica_set() {
  local out
  out="$(mongosh_admin --eval "
    try {
      const st = rs.status();
      if (st.ok === 1) { print('already_initiated'); quit(0); }
    } catch (e) {}
    const cfg = {
      _id: '${MONGO_REPLICA_SET}',
      members: [
        { _id: 0, host: 'wise-eat-mongo-1:27017', priority: 2 },
        { _id: 1, host: 'wise-eat-mongo-2:27017', priority: 1 },
        { _id: 2, host: 'wise-eat-mongo-3:27017', priority: 1 }
      ]
    };
    const res = rs.initiate(cfg);
    printjson(res);
    print('initiated');
  " 2>&1)" || {
    warn "rs.initiate a échoué ou a expiré :"
    echo "${out}" | sed 's/^/[wise-eat]   /'
    return 1
  }
  echo "${out}" | sed 's/^/[wise-eat]   /'
}

wait_for_replica_primary() {
  local max="${1:-90}"
  local state
  log "Attente élection PRIMARY (majorité 2/3 requise)…"
  for i in $(seq 1 "$max"); do
    state="$(mongosh_admin --eval "
      try {
        const s = rs.status();
        const p = s.members.find(m => m.stateStr === 'PRIMARY');
        print(p ? 'PRIMARY' : 'WAIT');
      } catch(e) { print('WAIT'); }
    " 2>/dev/null || echo WAIT)"
    if [[ "${state}" == "PRIMARY" ]]; then
      log "OK  replica set PRIMARY élu (~$((i * 2))s)"
      return 0
    fi
    if (( i % 5 == 0 )); then
      log "… attente PRIMARY ${i}/${max} (état=${state})"
    fi
    sleep 2
  done
  warn "PRIMARY non élu — rs.status() :"
  mongosh_admin --eval "rs.status()" 2>/dev/null | sed 's/^/[wise-eat]   /' || true
  return 1
}

if ! wait_for_mongo_primary 90; then
  docker logs --tail=40 wise-eat-mongo-1 2>&1 || true
  die "MongoDB primary injoignable — voir docker logs wise-eat-mongo-1"
fi
log "OK  MongoDB primary répond"

wait_for_mongo_cluster 90 || die "Les 3 nœuds MongoDB doivent être prêts avant rs.initiate() (majorité 2/3)"

log "Initialisation replica set ${MONGO_REPLICA_SET}…"
init_replica_set || die "rs.initiate() échoué — lancer : sudo ./install.sh repair-mongodb-replicaset"

wait_for_replica_primary 90 || die "PRIMARY non élu — lancer : sudo ./install.sh repair-mongodb-replicaset"

ensure_app_user() {
  docker exec wise-eat-mongo-1 mongosh -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASSWORD}" --authenticationDatabase admin --quiet --eval "
    const dbName = '${MONGO_APP_DATABASE}';
    const user = '${MONGO_APP_USER}';
    const pwd = '${MONGO_APP_PASSWORD}';
    const admin = db.getSiblingDB('admin');
    const users = admin.getUsers().users.map(u => u.user);
    if (!users.includes(user)) {
      admin.createUser({
        user: user,
        pwd: pwd,
        roles: [
          { role: 'readWrite', db: dbName },
          { role: 'dbAdmin', db: dbName }
        ]
      });
      print('app_user_created');
    } else {
      admin.updateUser(user, {
        pwd: pwd,
        roles: [
          { role: 'readWrite', db: dbName },
          { role: 'dbAdmin', db: dbName }
        ]
      });
      print('app_user_updated');
    }
  " 2>/dev/null || {
    docker exec wise-eat-mongo-1 mongosh --quiet --eval "
      db.getSiblingDB('${MONGO_APP_DATABASE}').createCollection('_init');
      db.getSiblingDB('admin').createUser({
        user: '${MONGO_APP_USER}',
        pwd: '${MONGO_APP_PASSWORD}',
        roles: [
          { role: 'readWrite', db: '${MONGO_APP_DATABASE}' },
          { role: 'dbAdmin', db: '${MONGO_APP_DATABASE}' }
        ]
      });
    " 2>/dev/null || warn "Création utilisateur applicatif — vérifier manuellement"
  }
}

ensure_app_user

docker compose --env-file .env.mongodb ps

if [[ "${MONGO_BACKUP_ENABLED:-1}" == "1" ]]; then
  bash "${SCRIPT_DIR}/install-mongodb-backup.sh"
fi

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-mongodb-admin.sh" 2>/dev/null || \
    warn "nginx MongoDB admin non configuré — sudo STUNNEL_TLS_EMAIL=... ./install.sh mongodb-admin"
fi

if [[ -f "/etc/letsencrypt/live/${MONGO_TLS_DOMAIN}/fullchain.pem" ]]; then
  bash "${SCRIPT_DIR}/install-mongodb-tls.sh" 2>/dev/null || true
else
  warn "TLS MongoDB absent — sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh mongodb-tls"
fi

bash "${SCRIPT_DIR}/repair-mongodb-prometheus.sh" 2>/dev/null || \
  warn "Monitoring MongoDB — relancer : sudo ./install.sh repair-mongodb-prometheus"

LOCAL_URI="mongodb://${MONGO_APP_USER}:${MONGO_APP_PASSWORD}@127.0.0.1:27017/${MONGO_APP_DATABASE}?authSource=${MONGO_APP_DATABASE}&replicaSet=${MONGO_REPLICA_SET}"
REMOTE_URI="mongodb://${MONGO_APP_USER}:${MONGO_APP_PASSWORD}@${MONGO_TLS_DOMAIN}:${MONGO_TLS_PORT:-27018}/${MONGO_APP_DATABASE}?authSource=${MONGO_APP_DATABASE}&replicaSet=${MONGO_REPLICA_SET}&tls=true"

cat <<EOF

MongoDB replica set ${MONGO_REPLICA_SET} (3 nœuds) :
  Primary   127.0.0.1:27017  (wise-eat-mongo-1)
  Replica 1 127.0.0.1:${MONGO_REPLICA_1_PORT:-27027}
  Replica 2 127.0.0.1:${MONGO_REPLICA_2_PORT:-27028}

TLS public (Stunnel) :
  ${MONGO_TLS_DOMAIN}:${MONGO_TLS_PORT:-27018} → primary

Console admin :
  https://${MONGO_ADMIN_DOMAIN} (basic auth nginx : ${MONGO_ADMIN_BASIC_AUTH_USER:-mongo-admin})

URI locale (PM2 sur VPS) :
  ${LOCAL_URI}

URI distante (TLS) :
  ${REMOTE_URI}

Secrets : ${MONGODB_DIR}/.env.mongodb
Backups : ${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}
Grafana : https://console.wise-eat.com → dossier MongoDB

EOF
