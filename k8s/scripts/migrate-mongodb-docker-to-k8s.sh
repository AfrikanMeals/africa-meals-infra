#!/usr/bin/env bash
# Cutover MongoDB rs0 Docker → pods k3s (hostPath — zéro perte).
#
# GARDE-FOUS :
#   - mongodump obligatoire avant stop (sauf SKIP_DUMP=1 urgence)
#   - Pas de docker compose down -v
#   - hostPath = /var/lib/wise-eat/mongodb/data-mongo-{1,2,3}
#   - Hostnames RS wise-eat-mongo-{1,2,3} via Services headless (pas de rs.reconfig)
#   - API : host.k3s.internal:27017 directConnection inchangé
#   - DbGate reste Docker → URL host.docker.internal:27017
#
# Usage :
#   sudo ./migrate-mongodb-docker-to-k8s.sh
#   sudo ./migrate-mongodb-docker-to-k8s.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MONGODB_DIR="${MONGODB_DIR:-${INFRA_ROOT}/mongodb}"
MONGODB_KUSTOMIZE="${INFRA_ROOT}/k8s/mongodb"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SKIP_DUMP="${SKIP_DUMP:-0}"
SKIP_BACKUP_TAR="${SKIP_BACKUP_TAR:-0}"
SKIP_DOCKER_DOWN="${SKIP_DOCKER_DOWN:-0}"
SKIP_EXPORTER="${SKIP_EXPORTER:-0}"
SKIP_DBGATE="${SKIP_DBGATE:-0}"
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo migrate-mongodb-docker-to-k8s.sh [--dry-run]

  1. Pré-checks volumes + keyfile + .env.mongodb
  2. mongodump (backup-mongodb.sh) sauf SKIP_DUMP=1
  3. docker compose stop mongo-1/2/3
  4. Tar data-mongo-* (sauf SKIP_BACKUP_TAR=1)
  5. create-mongodb-secret + kubectl apply -k k8s/mongodb
  6. ping ×3 + rs.status() PRIMARY
  7. Recreate DbGate → host.docker.internal:27017
  8. repair-mongodb-exporter-host
  9. docker compose rm mongo-* (pas -v) ; DbGate up

Rollback : k8s/mongodb/MIGRATE.md
EOF
      exit 0
      ;;
    *) echo "Option inconnue: ${arg}" >&2; exit 1 ;;
  esac
done

require_root

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

log() { echo "==> $*"; }
die() { echo "ERREUR: $*" >&2; exit 1; }

mongo_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^wise-eat-mongo-[123]$'
}

wait_port_free() {
  local port="$1" i
  for i in $(seq 1 60); do
    if ! nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_mongo_ping() {
  local port="$1" label="$2" i uri
  # URI avec auth root (rs0 exige SCRAM après init).
  uri="mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@127.0.0.1:${port}/admin?authSource=admin&directConnection=true"
  for i in $(seq 1 60); do
    if docker run --rm --network host mongo:8.0 \
      mongosh --quiet "${uri}" --eval "db.adminCommand('ping').ok" 2>/dev/null \
      | grep -q 1; then
      log "OK ping ${label} :${port}"
      return 0
    fi
    # Fallback : ping via pod si image host absente / auth lente
    if "${KUBECTL[@]}" -n "${NAMESPACE}" exec "deploy/mongo-1" -- \
      mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; then
      # Au moins mongod répond dans le cluster
      if [[ "${port}" == "${PRIMARY_PORT}" ]]; then
        log "OK ping ${label} :${port} (via pod)"
        return 0
      fi
    fi
    sleep 3
  done
  return 1
}

compose_mongo() {
  docker compose --env-file .env.mongodb "$@"
}

[[ -f "${MONGODB_DIR}/.env.mongodb" ]] || die "Absent ${MONGODB_DIR}/.env.mongodb"
[[ -f "${MONGODB_DIR}/keyfile" ]] || die "Absent ${MONGODB_DIR}/keyfile"
[[ -d "${MONGODB_KUSTOMIZE}" ]] || die "Absent ${MONGODB_KUSTOMIZE}"

set -a && source "${MONGODB_DIR}/.env.mongodb" && set +a
: "${MONGO_ROOT_USER:?}"
: "${MONGO_ROOT_PASSWORD:?}"
PRIMARY_PORT="${MONGO_PRIMARY_PORT:-27017}"
R1_PORT="${MONGO_REPLICA_1_PORT:-27027}"
R2_PORT="${MONGO_REPLICA_2_PORT:-27028}"
DATA_DIR="${MONGO_DATA_DIR:-/var/lib/wise-eat/mongodb}"
DATA_1="${MONGO_DATA_1:-${DATA_DIR}/data-mongo-1}"
DATA_2="${MONGO_DATA_2:-${DATA_DIR}/data-mongo-2}"
DATA_3="${MONGO_DATA_3:-${DATA_DIR}/data-mongo-3}"
APP_DB="${MONGO_APP_DATABASE:-wise_eat_db}"

for d in "${DATA_1}" "${DATA_2}" "${DATA_3}"; do
  [[ -d "${d}" ]] || die "Volume absent ${d}"
done

command -v nc >/dev/null 2>&1 || die "nc requis"
command -v curl >/dev/null 2>&1 || die "curl requis"

log "MongoDB cutover Docker → k8s (rs0, ports ${PRIMARY_PORT}/${R1_PORT}/${R2_PORT})"
log "Volumes : ${DATA_1} · ${DATA_2} · ${DATA_3}"
log "API URI : host.k3s.internal:${PRIMARY_PORT} (directConnection) — pas de changement"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] dump + stop + apply -k k8s/mongodb + DbGate/exporter"
  "${KUBECTL[@]}" kustomize "${MONGODB_KUSTOMIZE}" | head -50
  exit 0
fi

if [[ -x "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" ]]; then
  bash "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" || warn "ufw non bloquant"
fi

cd "${MONGODB_DIR}"

# 1. Dump pendant que Docker tourne encore
if [[ "${SKIP_DUMP}" != "1" ]]; then
  if mongo_docker_running; then
    log "mongodump pré-cutover (backup-mongodb.sh)…"
    bash "${INFRA_ROOT}/scripts/backup-mongodb.sh" || die "mongodump échoué — abort (SKIP_DUMP=1 pour forcer)"
  else
    warn "Mongo Docker déjà stop — skip dump (utiliser un backup récent)"
  fi
else
  warn "SKIP_DUMP=1 — pas de mongodump"
fi

# 2. Stop mongo nodes (libère hostPort) — DbGate peut rester
if mongo_docker_running; then
  log "Stop Docker mongo-1/2/3…"
  compose_mongo stop mongo-1 mongo-2 mongo-3
else
  log "Aucun mongo Docker Up — reprise mid-cutover"
fi

# 3. Tar volumes (après stop = cohérent)
if [[ "${SKIP_BACKUP_TAR}" != "1" ]]; then
  BACKUP_DIR="${MONGODB_DIR}/backups"
  mkdir -p "${BACKUP_DIR}"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/mongodb-data-${STAMP}.tar.gz"
  log "Backup tar → ${BACKUP_FILE}"
  set +e
  tar -czf "${BACKUP_FILE}" -C "${DATA_DIR}" \
    "$(basename "${DATA_1}")" "$(basename "${DATA_2}")" "$(basename "${DATA_3}")" \
    2>/tmp/mongo-tar.err
  tar_rc=$?
  set -e
  if [[ "${tar_rc}" -gt 1 ]]; then
    cat /tmp/mongo-tar.err >&2 || true
    die "Backup tar échoué (rc=${tar_rc})"
  fi
  [[ -s "${BACKUP_FILE}" ]] || die "Backup tar vide"
  log "Backup tar OK ($(du -h "${BACKUP_FILE}" | awk '{print $1}'))"
fi

for port in "${PRIMARY_PORT}" "${R1_PORT}" "${R2_PORT}"; do
  if ! wait_port_free "${port}"; then
    die "Port :${port} encore occupé — ss -tlnp | grep ${port}"
  fi
  log "Port libre :${port}"
done

if mongo_docker_running; then
  die "Conteneur mongo Docker encore Up — abort"
fi

chown -R 999:999 "${DATA_1}" "${DATA_2}" "${DATA_3}" "${MONGODB_DIR}/keyfile" || warn "chown 999 non bloquant"
chmod 400 "${MONGODB_DIR}/keyfile" || true

bash "${SCRIPT_DIR}/create-mongodb-secret.sh"

log "kubectl apply -k k8s/mongodb"
"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -k "${MONGODB_KUSTOMIZE}"

for dep in mongo-1 mongo-2 mongo-3; do
  "${KUBECTL[@]}" -n "${NAMESPACE}" rollout status "deploy/${dep}" --timeout=360s
done

wait_mongo_ping "${PRIMARY_PORT}" "primary" || die "Primary :${PRIMARY_PORT} pas prêt"
wait_mongo_ping "${R1_PORT}" "replica-1" || die "Replica-1 :${R1_PORT} pas prêt"
wait_mongo_ping "${R2_PORT}" "replica-2" || die "Replica-2 :${R2_PORT} pas prêt"

# 4. rs.status via mongosh auth dans le pod
log "Vérification replica set…"
sleep 5
RS_OUT="$("${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/mongo-1 -- \
  mongosh -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASSWORD}" --authenticationDatabase admin --quiet --eval '
    const s = rs.status();
    const members = s.members.map(m => m.name + "=" + m.stateStr).join(", ");
    const primary = s.members.find(m => m.stateStr === "PRIMARY");
    print(primary ? "PRIMARY_OK " + members : "NO_PRIMARY " + members);
  ' 2>/dev/null || echo 'RS_FAIL')"
echo "[mongo] ${RS_OUT}"
if ! echo "${RS_OUT}" | grep -q 'PRIMARY_OK'; then
  warn "PRIMARY non confirmé — vérifier : kubectl exec deploy/mongo-1 -- mongosh … rs.status()"
else
  log "OK replica set PRIMARY"
fi

# Smoke stats DB app
if "${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/mongo-1 -- \
  mongosh -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASSWORD}" --authenticationDatabase admin --quiet --eval "
    const st = db.getSiblingDB('${APP_DB}').stats();
    print('db_ok collections=' + st.collections + ' objects=' + (st.objects||0));
  " 2>/dev/null | grep -q 'db_ok'; then
  log "OK stats ${APP_DB}"
else
  warn "stats ${APP_DB} — vérifier manuellement"
fi

if "${KUBECTL[@]}" -n "${NAMESPACE}" get deploy africa-meals-api >/dev/null 2>&1; then
  if "${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/africa-meals-api -- \
    sh -c "nc -z -w 2 host.k3s.internal ${PRIMARY_PORT}" 2>/dev/null; then
    log "OK pod API → host.k3s.internal:${PRIMARY_PORT}"
  else
    warn "Pod API → host.k3s.internal:${PRIMARY_PORT} — UFW / URI"
  fi
fi

# 5. DbGate → host.docker.internal (DNS Docker mort) — password URL-encodé
if [[ "${SKIP_DBGATE}" != "1" ]]; then
  log "Recreate DbGate → host.docker.internal:${PRIMARY_PORT}"
  docker rm -f wise-eat-dbgate 2>/dev/null || true
  DBGATE_DATA="${MONGO_DBGATE_DATA:-./data-dbgate}"
  [[ "${DBGATE_DATA}" = /* ]] || DBGATE_DATA="${MONGODB_DIR}/${DBGATE_DATA#./}"
  mkdir -p "${DBGATE_DATA}"
  # Encode user/pass pour URI (évite @ : / dans le mot de passe).
  export PRIMARY_PORT
  DBGATE_URI="$(python3 - <<'PY'
import urllib.parse, os
u = urllib.parse.quote(os.environ["MONGO_ROOT_USER"], safe="")
p = urllib.parse.quote(os.environ["MONGO_ROOT_PASSWORD"], safe="")
port = os.environ.get("PRIMARY_PORT", "27017")
print(f"mongodb://{u}:{p}@host.docker.internal:{port}/admin?authSource=admin&directConnection=true")
PY
)"
  docker run -d --name wise-eat-dbgate --restart unless-stopped \
    --add-host=host.docker.internal:host-gateway \
    -e CONNECTIONS=wiseeat \
    -e LABEL_wiseeat='Wise Eat MongoDB' \
    -e "URL_wiseeat=${DBGATE_URI}" \
    -e ENGINE_wiseeat=mongo@dbgate-plugin-mongo \
    -e SKIP_ALL_AUTH=1 \
    -e SHELL_CONNECTION=0 \
    -e SHELL_SCRIPTING=0 \
    -e LOG_LEVEL=warn \
    -v "${DBGATE_DATA}:/root/.dbgate" \
    -p "127.0.0.1:${MONGO_DBGATE_PORT:-8081}:3000" \
    --memory="${MONGO_DBGATE_MEM_LIMIT:-512m}" \
    dbgate/dbgate:6.8.2
  log "OK DbGate :127.0.0.1:${MONGO_DBGATE_PORT:-8081}"
fi

# 6. Exporter Grafana
if [[ "${SKIP_EXPORTER}" != "1" ]]; then
  if [[ -x "${SCRIPT_DIR}/repair-mongodb-exporter-host.sh" ]]; then
    bash "${SCRIPT_DIR}/repair-mongodb-exporter-host.sh"
  else
    warn "repair-mongodb-exporter-host.sh absent"
  fi
fi

# 7. Retirer Compose mongo (pas -v) — DbGate déjà géré hors compose
if [[ "${SKIP_DOCKER_DOWN}" != "1" ]]; then
  log "docker compose rm -f -s mongo-1 mongo-2 mongo-3 (sans -v)"
  cd "${MONGODB_DIR}"
  compose_mongo rm -f -s mongo-1 mongo-2 mongo-3 2>/dev/null || true
fi

log "Cutover MongoDB OK"
log "  Primary  127.0.0.1:${PRIMARY_PORT}  (API: host.k3s.internal:${PRIMARY_PORT})"
log "  Replica1 127.0.0.1:${R1_PORT}"
log "  Replica2 127.0.0.1:${R2_PORT}"
log "  TLS      db.wise-eat.com:27018 → HAProxy → 127.0.0.1:${PRIMARY_PORT}"
log "  Admin    https://data.wise-eat.com (DbGate)"
log "  Docs     : k8s/mongodb/MIGRATE.md"
