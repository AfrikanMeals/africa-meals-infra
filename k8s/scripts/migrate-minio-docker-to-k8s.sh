#!/usr/bin/env bash
# Cutover MinIO Docker Compose → pods k3s (hostPath = mêmes volumes — zéro copie).
#
# GARDE-FOUS PROD :
#   - Pas de docker compose down -v
#   - Pas de mc admin replicate add (peut rb --force les buckets réplicas)
#   - Refuse d’appliquer les pods si un conteneur MinIO Docker est encore Up
#   - Backup mc mirror obligatoire avant stop (sauf SKIP_BACKUP=1)
#
# Usage (VPS root) :
#   sudo ./migrate-minio-docker-to-k8s.sh
#   sudo ./migrate-minio-docker-to-k8s.sh --dry-run
#   sudo SKIP_BACKUP=1 ./migrate-minio-docker-to-k8s.sh   # urgence seulement
#   sudo API_ENV=/opt/wise-eat-api/.env.prod ./migrate-minio-docker-to-k8s.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MINIO_DIR="${MINIO_DIR:-${INFRA_ROOT}/minio}"
MINIO_KUSTOMIZE="${INFRA_ROOT}/k8s/minio"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"
# shellcheck source=api-paths.sh
source "${SCRIPT_DIR}/api-paths.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
SKIP_API_SECRET="${SKIP_API_SECRET:-0}"
SKIP_DOCKER_DOWN="${SKIP_DOCKER_DOWN:-0}"
DRY_RUN=false
API_ENV_ARG="${API_ENV:-}"

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo migrate-minio-docker-to-k8s.sh [--dry-run]

  1. Pré-checks volumes + health Docker
  2. Backup mc mirror (obligatoire)
  3. docker compose stop (pas down -v)
  4. Secret + kubectl apply -k k8s/minio
  5. Health 127.0.0.1:9000/9002/9004 + HTTPS public
  6. Bascule MINIO_ENDPOINT API → host.k3s.internal:9000
  7. docker compose down (sans -v) après validation

Rollback : voir k8s/minio/MIGRATE.md
EOF
      exit 0
      ;;
    *)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

require_root

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

log() { echo "==> $*"; }
die() { echo "ERREUR: $*" >&2; exit 1; }

minio_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^wise-eat-minio(-replica-[12])?$'
}

# Après docker stop : plus de health MinIO = port libre pour hostPort K8s.
wait_port_free() {
  local port="$1"
  local i
  for i in $(seq 1 30); do
    if ! curl -sf "http://127.0.0.1:${port}/minio/health/live" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_minio_health() {
  local port="$1"
  local label="$2"
  local i
  for i in $(seq 1 45); do
    if curl -sf "http://127.0.0.1:${port}/minio/health/live" >/dev/null 2>&1; then
      log "OK health ${label} :127.0.0.1:${port}"
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- Pré-checks ---
[[ -f "${MINIO_DIR}/.env.minio" ]] || die "Absent ${MINIO_DIR}/.env.minio"
[[ -d "${MINIO_KUSTOMIZE}" ]] || die "Absent ${MINIO_KUSTOMIZE}"

set -a && source "${MINIO_DIR}/.env.minio" && set +a
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}"
MINIO_REPLICA_1_DATA_DIR="${MINIO_REPLICA_1_DATA_DIR:-/var/lib/wise-eat/minio-replica-1}"
MINIO_REPLICA_2_DATA_DIR="${MINIO_REPLICA_2_DATA_DIR:-/var/lib/wise-eat/minio-replica-2}"
API_PORT="${MINIO_API_PORT:-9000}"
R1_PORT="${MINIO_REPLICA_1_API_PORT:-9002}"
R2_PORT="${MINIO_REPLICA_2_API_PORT:-9004}"

for d in "${MINIO_DATA_DIR}" "${MINIO_REPLICA_1_DATA_DIR}" "${MINIO_REPLICA_2_DATA_DIR}"; do
  [[ -d "${d}" ]] || die "Volume données absent (ne pas créer vide en prod) : ${d}"
  [[ -n "$(ls -A "${d}" 2>/dev/null || true)" ]] || die "Volume vide — abort pour éviter perte : ${d}"
  log "Volume OK : ${d} ($(du -sh "${d}" 2>/dev/null | awk '{print $1}'))"
done

if ! command -v "${KUBECTL[0]}" >/dev/null 2>&1 && [[ "${KUBECTL[0]}" != "sudo" ]]; then
  die "kubectl / k3s kubectl introuvable"
fi

log "Pré-check health Docker MinIO (si Up)"
if minio_docker_running; then
  wait_for_minio_local "${API_PORT}" 15 || warn "Primaire Docker ne répond pas encore"
else
  warn "Aucun conteneur MinIO Docker Up — cutover depuis état déjà arrêté ?"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  log "DRY-RUN : backup + stop + apply non exécutés"
  log "kubectl kustomize ${MINIO_KUSTOMIZE} :"
  "${KUBECTL[@]}" kustomize "${MINIO_KUSTOMIZE}" | head -n 40
  exit 0
fi

# --- Backup obligatoire ---
if [[ "${SKIP_BACKUP}" != "1" ]]; then
  log "Backup mc mirror (obligatoire avant stop)"
  bash "${INFRA_ROOT}/scripts/backup-minio.sh" || die "Backup échoué — cutover annulé (données intactes)"
else
  warn "SKIP_BACKUP=1 — cutover sans mirror (risque)"
fi

# --- UFW pods → ports MinIO (hostPort sur cni0) ---
if command -v ufw >/dev/null 2>&1; then
  log "UFW : autoriser CIDR pods → ports MinIO"
  bash "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" || warn "ufw-allow-k3s-pods.sh a échoué (vérifier manuellement)"
fi

# --- Stop Docker (garde les volumes host) ---
log "Arrêt conteneurs MinIO Docker (stop — pas down -v)"
cd "${MINIO_DIR}"
if [[ -f docker-compose.replicas.yml ]]; then
  docker compose --env-file .env.minio \
    -f docker-compose.yml \
    -f docker-compose.replicas.yml stop || true
else
  docker compose --env-file .env.minio stop || true
fi

# Garde anti double-writer : pods refusés tant que Docker Up.
if minio_docker_running; then
  die "Conteneur MinIO Docker encore Up — arrêter manuellement avant apply K8s"
fi

for port in "${API_PORT}" "${R1_PORT}" "${R2_PORT}"; do
  log "Attente libération port :${port}"
  wait_port_free "${port}" || warn "Port :${port} encore ouvert — apply peut échouer (hostPort)"
done

# --- Secret + apply ---
log "Secret minio-env depuis .env.minio"
bash "${SCRIPT_DIR}/create-minio-secret.sh"

log "kubectl apply -k ${MINIO_KUSTOMIZE}"
"${KUBECTL[@]}" apply -k "${MINIO_KUSTOMIZE}"

log "Attente Ready Deployments MinIO"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/minio --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/minio-replica-1 --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/minio-replica-2 --timeout=180s

wait_minio_health "${API_PORT}" "primaire" || die "Primaire K8s ne répond pas — rollback : scale deploy=0 puis docker compose up -d"
wait_minio_health "${R1_PORT}" "réplica-1" || die "Réplica 1 K8s down — voir MIGRATE.md rollback"
wait_minio_health "${R2_PORT}" "réplica-2" || die "Réplica 2 K8s down — voir MIGRATE.md rollback"

# Smoke public (nginx inchangé → 127.0.0.1:9000)
STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
if curl -sfI "https://${STORAGE_DOMAIN}/minio/health/live" >/dev/null 2>&1 \
  || curl -sf "https://${STORAGE_DOMAIN}/minio/health/live" >/dev/null 2>&1; then
  log "OK HTTPS public https://${STORAGE_DOMAIN}"
else
  warn "HTTPS ${STORAGE_DOMAIN} non vérifié (DNS/cert) — health local OK"
fi

# --- Bascule secret API ---
if [[ "${SKIP_API_SECRET}" != "1" ]]; then
  RESOLVED_ENV=""
  if RESOLVED_ENV="$(api_resolve_env_file "${API_ENV_ARG}" 2>/dev/null)"; then
    log "Bascule MINIO_ENDPOINT → http://host.k3s.internal:9000 (${RESOLVED_ENV})"
    bash "${SCRIPT_DIR}/create-api-secret.sh" "${RESOLVED_ENV}"
    if "${KUBECTL[@]}" -n "${NAMESPACE}" get deploy africa-meals-api >/dev/null 2>&1; then
      "${KUBECTL[@]}" -n "${NAMESPACE}" rollout restart deploy/africa-meals-api
      "${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/africa-meals-api --timeout=300s || \
        warn "Rollout API non terminé — vérifier manuellement"
    fi
  else
    warn "API .env.prod introuvable — lancer create-api-secret.sh manuellement après cutover"
  fi
fi

# --- Retirer containers Docker (volumes host intacts) ---
if [[ "${SKIP_DOCKER_DOWN}" != "1" ]]; then
  log "docker compose down (sans -v) — volumes /var/lib/wise-eat/minio* inchangés"
  cd "${MINIO_DIR}"
  if [[ -f docker-compose.replicas.yml ]]; then
    docker compose --env-file .env.minio \
      -f docker-compose.yml \
      -f docker-compose.replicas.yml down
  else
    docker compose --env-file .env.minio down
  fi
else
  warn "SKIP_DOCKER_DOWN=1 — containers Docker laissés stopped"
fi

cat <<EOF

=== Cutover MinIO → K8s terminé ===

Interne (pods API) : http://host.k3s.internal:9000
Public             : https://${STORAGE_DOMAIN}
Console            : https://${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}
Volumes (inchangés):
  ${MINIO_DATA_DIR}
  ${MINIO_REPLICA_1_DATA_DIR}
  ${MINIO_REPLICA_2_DATA_DIR}

NE PAS lancer : install.sh minio-replication (mc replicate add destructif)
Rollback      : voir ${MINIO_KUSTOMIZE}/MIGRATE.md
EOF
