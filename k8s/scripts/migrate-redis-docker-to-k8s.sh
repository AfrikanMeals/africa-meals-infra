#!/usr/bin/env bash
# Cutover Redis Docker → pods k3s (hostPath AOF + hostPort — zéro perte données).
#
# GARDE-FOUS :
#   - Pas de docker compose down -v
#   - hostPath = /opt/wise-eat/redis/data-* (mêmes dossiers Docker)
#   - Secret ACL depuis .env.redis (mêmes mots de passe)
#   - replicaof → Services *.svc.cluster.local (plus DNS Docker)
#   - API : REDIS_PASSWORD / BULLMQ_* doivent matcher .env.redis
#
# Usage :
#   sudo ./migrate-redis-docker-to-k8s.sh
#   sudo ./migrate-redis-docker-to-k8s.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REDIS_DIR="${REDIS_DIR:-${INFRA_ROOT}/redis}"
REDIS_KUSTOMIZE="${INFRA_ROOT}/k8s/redis"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
SKIP_DOCKER_DOWN="${SKIP_DOCKER_DOWN:-0}"
SKIP_EXPORTERS="${SKIP_EXPORTERS:-0}"
SKIP_API_SECRET="${SKIP_API_SECRET:-1}"
DRY_RUN=false
API_ENV_ARG="${API_ENV:-}"

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo migrate-redis-docker-to-k8s.sh [--dry-run]

  1. Pré-checks volumes data-* + .env.redis
  2. Backup tar data-* (sauf SKIP_BACKUP=1)
  3. create-redis-secret.sh (ACL + replicaof k8s)
  4. docker compose stop
  5. kubectl apply LimitRange (max 2Gi) + k8s/redis
  6. PING ACL sur 6 ports
  7. repair-redis-exporters-host
  8. docker compose down (sans -v)

Rollback : k8s/redis/MIGRATE.md
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

redis_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^wise-eat-redis-(cache|bullmq)(-replica-[12])?$'
}

wait_port_free() {
  local port="$1" i
  for i in $(seq 1 40); do
    if ! nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ping_local() {
  local port="$1" user="$2" pass="$3" label="$4" i
  for i in $(seq 1 45); do
    if redis-cli -h 127.0.0.1 -p "${port}" --user "${user}" --pass "${pass}" ping 2>/dev/null | grep -q PONG; then
      log "OK PING ${label} :${port}"
      return 0
    fi
    # Fallback sans redis-cli hôte : docker run
    if docker run --rm --network host redis:7-alpine \
      redis-cli -h 127.0.0.1 -p "${port}" --user "${user}" --pass "${pass}" ping 2>/dev/null | grep -q PONG; then
      log "OK PING ${label} :${port} (via container)"
      return 0
    fi
    sleep 2
  done
  return 1
}

compose_redis() {
  local args=(--env-file .env.redis)
  if redis_cluster_b_enabled 2>/dev/null || [[ "${REDIS_CLUSTER_B_ENABLED:-true}" == "true" ]]; then
    args+=(--profile cluster-b)
  fi
  docker compose "${args[@]}" "$@"
}

[[ -f "${REDIS_DIR}/.env.redis" ]] || die "Absent ${REDIS_DIR}/.env.redis"
[[ -d "${REDIS_KUSTOMIZE}" ]] || die "Absent ${REDIS_KUSTOMIZE}"

set -a && source "${REDIS_DIR}/.env.redis" && set +a
: "${CACHE_REDIS_PASSWORD:?}"
: "${BULL_REDIS_PASSWORD:?}"

DATA_DIRS=(
  data-cache
  data-bullmq
  data-cache-replica-1
  data-cache-replica-2
  data-bullmq-replica-1
  data-bullmq-replica-2
)

log "Redis cutover Docker → k8s (AOF hostPath /opt/wise-eat/redis/data-*)"
log "Credentials : ACL depuis .env.redis (pas de regen aléatoire)"

# hostPath manifests = /opt/wise-eat/redis — vérifier alignement
EXPECTED_ROOT="/opt/wise-eat/redis"
REAL_ROOT="$(cd "${REDIS_DIR}" && pwd)"
if [[ "${REAL_ROOT}" != "${EXPECTED_ROOT}" ]]; then
  warn "REDIS_DIR=${REAL_ROOT} ≠ ${EXPECTED_ROOT}"
  warn "Les manifests hostPath pointent vers ${EXPECTED_ROOT}/data-* — ajuster ou symlink"
fi

for d in "${DATA_DIRS[@]}"; do
  path="${REDIS_DIR}/${d}"
  [[ -d "${path}" ]] || die "Volume absent (ne pas créer vide en prod) : ${path}"
done
# Primaries doivent avoir des données (AOF)
for d in data-cache data-bullmq; do
  [[ -n "$(ls -A "${REDIS_DIR}/${d}" 2>/dev/null || true)" ]] \
    || die "Volume primary vide — abort : ${REDIS_DIR}/${d}"
  log "Volume OK : ${d} ($(du -sh "${REDIS_DIR}/${d}" | awk '{print $1}'))"
done

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] backup + secret + stop + apply -k k8s/redis + exporters"
  "${KUBECTL[@]}" kustomize "${REDIS_KUSTOMIZE}" | head -50
  exit 0
fi

command -v nc >/dev/null 2>&1 || die "nc requis"

# 1. UFW
[[ -x "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" ]] \
  && bash "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" || true

# 2. Secret ACL + replicaof k8s (avant stop — pas de dépendance runtime)
bash "${SCRIPT_DIR}/create-redis-secret.sh"

# 3. LimitRange max 2Gi — appliquer API ET WS (plusieurs LimitRange = le max le plus bas gagne).
for lr in \
  "${INFRA_ROOT}/k8s/africa-meals-api/limitrange.yaml" \
  "${INFRA_ROOT}/k8s/africa-meals-ws/limitrange.yaml"; do
  if [[ -f "${lr}" ]]; then
    log "Apply LimitRange $(basename "$(dirname "${lr}")")"
    "${KUBECTL[@]}" apply -f "${lr}" || true
  fi
done
# Vérifier qu’aucun LimitRange ne reste à max 512Mi
if "${KUBECTL[@]}" -n "${NAMESPACE}" get limitrange -o jsonpath='{range .items[*]}{.metadata.name}{" max="}{.spec.limits[0].max.memory}{"\n"}{end}' 2>/dev/null \
  | grep -q '512Mi'; then
  die "LimitRange max encore 512Mi — kubectl -n ${NAMESPACE} get limitrange -o yaml"
fi

# 4. Stop Docker AVANT backup — AOF figé (évite « file changed as we read it »)
cd "${REDIS_DIR}"
if redis_docker_running; then
  log "Stop Redis Docker (avant backup cohérent)…"
  compose_redis stop
else
  log "Aucun Redis Docker Up — reprise mid-cutover"
fi

PORTS=(6379 6380 6371 6372 6390 6391)
for port in "${PORTS[@]}"; do
  wait_port_free "${port}" || die "Port :${port} encore occupé"
  log "Port libre :${port}"
done

if redis_docker_running; then
  die "Conteneur Redis Docker encore Up — abort"
fi

# 5. Backup tar sur volumes arrêtés
if [[ "${SKIP_BACKUP}" != "1" ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BAK="/var/backups/wise-eat-redis/pre-k8s-${STAMP}"
  mkdir -p "${BAK}"
  log "Backup AOF → ${BAK}"
  # tar exit 1 = fichier modifié pendant lecture (non fatal si archive créée)
  set +e
  tar -C "${REDIS_DIR}" -czf "${BAK}/redis-data.tgz" "${DATA_DIRS[@]}"
  tar_rc=$?
  set -e
  if [[ ! -s "${BAK}/redis-data.tgz" ]]; then
    die "Backup tar vide ou absent — abort"
  fi
  if [[ "${tar_rc}" -gt 1 ]]; then
    die "Backup tar échoué (rc=${tar_rc})"
  fi
  if [[ "${tar_rc}" -eq 1 ]]; then
    warn "tar rc=1 (fichier modifié) — archive quand même utilisée (Redis déjà stop)"
  fi
  log "Backup OK ($(du -sh "${BAK}/redis-data.tgz" | awk '{print $1}'))"
fi

# Permissions UID Redis
chown -R 999:999 "${REDIS_DIR}/data-cache" "${REDIS_DIR}/data-bullmq" \
  "${REDIS_DIR}/data-cache-replica-1" "${REDIS_DIR}/data-cache-replica-2" \
  "${REDIS_DIR}/data-bullmq-replica-1" "${REDIS_DIR}/data-bullmq-replica-2" 2>/dev/null || true

# 6. Apply pods
log "kubectl apply -k k8s/redis"
"${KUBECTL[@]}" apply -k "${REDIS_KUSTOMIZE}"

# Primaries d'abord (rollout status)
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/redis-cache --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/redis-bullmq --timeout=180s
for dep in redis-cache-replica-1 redis-cache-replica-2 redis-bullmq-replica-1 redis-bullmq-replica-2; do
  "${KUBECTL[@]}" -n "${NAMESPACE}" rollout status "deploy/${dep}" --timeout=180s
done

# 7. Health PING
ping_local 6379 wise-eat-cache "${CACHE_REDIS_PASSWORD}" "cache-primary" || die "cache primary"
ping_local 6380 wise-eat-bull "${BULL_REDIS_PASSWORD}" "bull-primary" || die "bull primary"
ping_local 6371 wise-eat-cache "${CACHE_REDIS_PASSWORD}" "cache-r1" || die "cache r1"
ping_local 6372 wise-eat-cache "${CACHE_REDIS_PASSWORD}" "cache-r2" || die "cache r2"
ping_local 6390 wise-eat-bull "${BULL_REDIS_PASSWORD}" "bull-r1" || die "bull r1"
ping_local 6391 wise-eat-bull "${BULL_REDIS_PASSWORD}" "bull-r2" || die "bull r2"

# 8. Exporters Grafana
if [[ "${SKIP_EXPORTERS}" != "1" ]]; then
  bash "${SCRIPT_DIR}/repair-redis-exporters-host.sh"
fi

# 9. Optionnel : resync secret API (mots de passe)
if [[ "${SKIP_API_SECRET}" != "1" && -n "${API_ENV_ARG}" ]]; then
  log "create-api-secret depuis ${API_ENV_ARG}"
  bash "${SCRIPT_DIR}/create-api-secret.sh" "${API_ENV_ARG}" || warn "create-api-secret échoué"
fi

# 10. Down Docker
if [[ "${SKIP_DOCKER_DOWN}" != "1" ]]; then
  log "docker compose down (sans -v)"
  compose_redis down || true
fi

log "Cutover Redis OK"
log "  Cache  :6379  Bull :6380  réplicas :6371/:6372/:6390/:6391"
log "  Vérifier API REDIS_PASSWORD == CACHE_REDIS_PASSWORD (.env.prod vs .env.redis)"
log "  Docs   : k8s/redis/MIGRATE.md"
