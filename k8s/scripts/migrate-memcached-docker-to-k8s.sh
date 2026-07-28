#!/usr/bin/env bash
# Cutover Memcached Docker Compose → pods k3s (hostPort, pas de volume).
#
# IMPORTANT :
#   - Memcached = cache RAM : redémarrage = cache froid (pas de perte durable).
#   - Pas de SASL / credentials (contrairement à Redis/MinIO).
#   - Ports inchangés : 11211 / 11213 / 11214 (API déjà sur host.k3s.internal).
#   - Exporters Grafana : bascule vers network_mode host + 127.0.0.1 (DNS Docker morts).
#
# Usage (VPS root) :
#   sudo ./migrate-memcached-docker-to-k8s.sh
#   sudo ./migrate-memcached-docker-to-k8s.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MEMCACHED_DIR="${MEMCACHED_DIR:-${INFRA_ROOT}/memcached}"
MEMCACHED_KUSTOMIZE="${INFRA_ROOT}/k8s/memcached"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SKIP_DOCKER_DOWN="${SKIP_DOCKER_DOWN:-0}"
SKIP_EXPORTERS="${SKIP_EXPORTERS:-0}"
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo migrate-memcached-docker-to-k8s.sh [--dry-run]

  1. Pré-checks .env.memcached + kubectl
  2. ufw-allow-k3s-pods (CIDR → 11211/11213/11214)
  3. docker compose stop (pas down -v — N/A volumes)
  4. kubectl apply -k k8s/memcached
  5. Health TCP :11211/:11213/:11214
  6. Recreate exporters host-network (Grafana memcached_up)
  7. docker compose down (sans -v)

Rollback : voir k8s/memcached/MIGRATE.md
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

memcached_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^wise-eat-memcached(-replica-[12])?$'
}

# Port libre = nc échoue (plus de listener Docker).
wait_port_free() {
  local port="$1"
  local i
  for i in $(seq 1 30); do
    if ! nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Health Memcached : commande stats via TCP.
wait_memcached_stats() {
  local port="$1"
  local label="$2"
  local i out
  for i in $(seq 1 45); do
    out="$(printf 'stats\nquit\n' | nc -w 2 127.0.0.1 "${port}" 2>/dev/null || true)"
    if printf '%s' "${out}" | grep -q 'STAT '; then
      log "OK health ${label} :127.0.0.1:${port}"
      return 0
    fi
    sleep 2
  done
  return 1
}

compose_memcached() {
  local args=(--env-file .env.memcached)
  if memcached_cluster_b_enabled 2>/dev/null || [[ "${MEMCACHED_CLUSTER_B_ENABLED:-true}" == "true" ]]; then
    args+=(--profile cluster-b)
  fi
  docker compose "${args[@]}" "$@"
}

# --- Pré-checks ---
[[ -f "${MEMCACHED_DIR}/.env.memcached" ]] || die "Absent ${MEMCACHED_DIR}/.env.memcached — sudo ./install.sh memcached d'abord"
[[ -d "${MEMCACHED_KUSTOMIZE}" ]] || die "Absent ${MEMCACHED_KUSTOMIZE}"

set -a && source "${MEMCACHED_DIR}/.env.memcached" && set +a
PRIMARY_PORT="${MEMCACHED_PORT:-11211}"
R1_PORT="${MEMCACHED_REPLICA_1_PORT:-11213}"
R2_PORT="${MEMCACHED_REPLICA_2_PORT:-11214}"

if ! command -v "${KUBECTL[0]}" >/dev/null 2>&1 && [[ "${KUBECTL[0]}" != "sudo" ]]; then
  die "kubectl / k3s kubectl introuvable"
fi
command -v nc >/dev/null 2>&1 || die "nc (netcat) requis pour les probes TCP"

log "Memcached cutover Docker → k8s (ports ${PRIMARY_PORT}/${R1_PORT}/${R2_PORT})"
log "Note : cache RAM — pas de backup objets (froid au restart, attendu)"
log "Credentials : aucun (pas de SASL) — API inchangée (host.k3s.internal)"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] ufw-allow-k3s-pods + compose stop + apply -k k8s/memcached + exporters host"
  "${KUBECTL[@]}" kustomize "${MEMCACHED_KUSTOMIZE}" | head -40
  exit 0
fi

# 1. UFW pods → ports Memcached
if [[ -x "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" ]]; then
  bash "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" || warn "ufw-allow-k3s-pods non bloquant"
fi

# 2. Stop Docker (libère hostPort) — jamais down -v (inutile mais garde le pattern)
cd "${MEMCACHED_DIR}"
if memcached_docker_running; then
  log "Stop conteneurs Docker Memcached…"
  compose_memcached stop
else
  log "Aucun conteneur Memcached Docker Up — reprise mid-cutover"
fi

for port in "${PRIMARY_PORT}" "${R1_PORT}" "${R2_PORT}"; do
  if ! wait_port_free "${port}"; then
    die "Port :${port} encore occupé — docker ps | grep memcached ; lsof -i :${port}"
  fi
  log "Port libre :${port}"
done

# 3. Refuse apply si Docker encore Up (double writer hostPort)
if memcached_docker_running; then
  die "Conteneur Memcached Docker encore Up — abort"
fi

# 4. Apply pods
log "kubectl apply -k k8s/memcached"
"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -k "${MEMCACHED_KUSTOMIZE}"

for dep in memcached memcached-replica-1 memcached-replica-2; do
  "${KUBECTL[@]}" -n "${NAMESPACE}" rollout status "deploy/${dep}" --timeout=180s
done

# 5. Health TCP
wait_memcached_stats "${PRIMARY_PORT}" "primary" || die "Primary :${PRIMARY_PORT} pas prêt"
wait_memcached_stats "${R1_PORT}" "replica-1" || die "Replica-1 :${R1_PORT} pas prêt"
wait_memcached_stats "${R2_PORT}" "replica-2" || die "Replica-2 :${R2_PORT} pas prêt"

# 6. Smoke depuis un pod API si présent
if "${KUBECTL[@]}" -n "${NAMESPACE}" get deploy africa-meals-api >/dev/null 2>&1; then
  if "${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/africa-meals-api -- \
    sh -c "printf 'version\nquit\n' | nc -w 2 host.k3s.internal ${PRIMARY_PORT}" 2>/dev/null \
    | grep -qi memcached; then
    log "OK pod API → host.k3s.internal:${PRIMARY_PORT}"
  else
    warn "Pod API → host.k3s.internal:${PRIMARY_PORT} — vérifier UFW / MEMCACHED_SERVERS"
  fi
fi

# 7. Exporters Grafana (DNS Docker wise-eat-memcached morts)
if [[ "${SKIP_EXPORTERS}" != "1" ]]; then
  if [[ -x "${SCRIPT_DIR}/repair-memcached-exporters-host.sh" ]]; then
    bash "${SCRIPT_DIR}/repair-memcached-exporters-host.sh"
  else
    warn "repair-memcached-exporters-host.sh absent — Grafana memcached_up peut rester DOWN"
  fi
fi

# 8. Retirer Compose Memcached (pas -v)
if [[ "${SKIP_DOCKER_DOWN}" != "1" ]]; then
  log "docker compose down (sans -v)"
  compose_memcached down || true
fi

log "Cutover Memcached OK"
log "  Primary  127.0.0.1:${PRIMARY_PORT}  (API: host.k3s.internal:${PRIMARY_PORT})"
log "  Replica1 127.0.0.1:${R1_PORT}"
log "  Replica2 127.0.0.1:${R2_PORT}"
log "  Grafana  : curl -s http://127.0.0.1:9150/metrics | grep memcached_up"
log "  Docs     : k8s/memcached/MIGRATE.md"
