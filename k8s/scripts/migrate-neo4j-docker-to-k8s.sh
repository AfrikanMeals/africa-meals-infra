#!/usr/bin/env bash
# Cutover Neo4j Docker → pods k3s (hostPath /var/lib/wise-eat/neo4j — zéro perte).
#
# GARDE-FOUS :
#   - Pas de docker compose down -v
#   - hostPath = NEO4J_DATA_DIR (même volume loop 5 Go)
#   - Secret auth depuis .env.neo4j (pas de regen cutover)
#   - Ports 7474/7687 inchangés (nginx db-graph + API host.k3s.internal)
#   - Exporter Grafana → 127.0.0.1:7687 (DNS Docker mort)
#
# Usage :
#   sudo ./migrate-neo4j-docker-to-k8s.sh
#   sudo ./migrate-neo4j-docker-to-k8s.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NEO4J_DIR="${NEO4J_DIR:-${INFRA_ROOT}/neo4j}"
NEO4J_KUSTOMIZE="${INFRA_ROOT}/k8s/neo4j"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
SKIP_DOCKER_DOWN="${SKIP_DOCKER_DOWN:-0}"
SKIP_EXPORTER="${SKIP_EXPORTER:-0}"
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo migrate-neo4j-docker-to-k8s.sh [--dry-run]

  1. Pré-checks volume + .env.neo4j
  2. Stop Docker → backup tar data/ (sauf SKIP_BACKUP=1)
  3. create-neo4j-secret.sh
  4. kubectl apply -k k8s/neo4j
  5. Health HTTP :7474 + cypher-shell RETURN 1
  6. repair-neo4j-exporter-host (Grafana)
  7. docker compose down (sans -v)

Rollback : k8s/neo4j/MIGRATE.md
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

neo4j_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-neo4j'
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

wait_neo4j_http() {
  local port="$1" i
  for i in $(seq 1 60); do
    if curl -sf --max-time 3 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      log "OK health HTTP :127.0.0.1:${port}"
      return 0
    fi
    sleep 3
  done
  return 1
}

compose_neo4j() {
  docker compose --env-file .env.neo4j "$@"
}

[[ -f "${NEO4J_DIR}/.env.neo4j" ]] || die "Absent ${NEO4J_DIR}/.env.neo4j"
[[ -d "${NEO4J_KUSTOMIZE}" ]] || die "Absent ${NEO4J_KUSTOMIZE}"

set -a && source "${NEO4J_DIR}/.env.neo4j" && set +a
: "${NEO4J_PASSWORD:?}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
HTTP_PORT="${NEO4J_HTTP_PORT:-7474}"
BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
DATA_DIR="${NEO4J_DATA_DIR:-/var/lib/wise-eat/neo4j}"

for sub in data logs import plugins; do
  [[ -d "${DATA_DIR}/${sub}" ]] || die "Volume absent ${DATA_DIR}/${sub} — sudo ./install.sh neo4j d'abord"
done

command -v nc >/dev/null 2>&1 || die "nc (netcat) requis"
command -v curl >/dev/null 2>&1 || die "curl requis"

log "Neo4j cutover Docker → k8s (ports ${HTTP_PORT}/${BOLT_PORT})"
log "Volume : ${DATA_DIR} — auth depuis .env.neo4j"
log "API : bolt://host.k3s.internal:${BOLT_PORT} (inchangé si déjà configuré)"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] secret + stop + apply -k k8s/neo4j + exporter host"
  "${KUBECTL[@]}" kustomize "${NEO4J_KUSTOMIZE}" | head -40
  exit 0
fi

if [[ -x "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" ]]; then
  bash "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" || warn "ufw-allow-k3s-pods non bloquant"
fi

cd "${NEO4J_DIR}"

# Stop avant backup (fichiers store cohérents).
if neo4j_docker_running; then
  log "Stop Docker Neo4j…"
  compose_neo4j stop
else
  log "Aucun conteneur Neo4j Docker Up — reprise mid-cutover"
fi

if [[ "${SKIP_BACKUP}" != "1" ]]; then
  BACKUP_DIR="${NEO4J_DIR}/backups"
  mkdir -p "${BACKUP_DIR}"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/neo4j-data-${STAMP}.tar.gz"
  log "Backup → ${BACKUP_FILE}"
  set +e
  tar -czf "${BACKUP_FILE}" -C "${DATA_DIR}" data logs import plugins 2>/tmp/neo4j-tar.err
  tar_rc=$?
  set -e
  if [[ "${tar_rc}" -gt 1 ]]; then
    cat /tmp/neo4j-tar.err >&2 || true
    die "Backup tar échoué (rc=${tar_rc})"
  fi
  [[ -s "${BACKUP_FILE}" ]] || die "Backup vide"
  log "Backup OK ($(du -h "${BACKUP_FILE}" | awk '{print $1}'))"
fi

for port in "${HTTP_PORT}" "${BOLT_PORT}"; do
  if ! wait_port_free "${port}"; then
    die "Port :${port} encore occupé — docker ps | grep neo4j ; ss -tlnp | grep ${port}"
  fi
  log "Port libre :${port}"
done

if neo4j_docker_running; then
  die "Conteneur Neo4j Docker encore Up — abort"
fi

# UID image officielle
chown -R 7474:7474 "${DATA_DIR}" || warn "chown 7474 ${DATA_DIR} non bloquant"

bash "${SCRIPT_DIR}/create-neo4j-secret.sh"

log "kubectl apply -k k8s/neo4j"
"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -k "${NEO4J_KUSTOMIZE}"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/neo4j --timeout=300s

wait_neo4j_http "${HTTP_PORT}" || die "HTTP :${HTTP_PORT} pas prêt"

# Smoke Bolt via cypher-shell dans le pod
if "${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/neo4j -- \
  cypher-shell -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" 'RETURN 1 AS ok;' 2>/dev/null \
  | grep -q '1'; then
  log "OK cypher-shell RETURN 1"
else
  warn "cypher-shell — vérifier NEO4J_PASSWORD / logs deploy/neo4j"
fi

# Smoke depuis pod API si présent
if "${KUBECTL[@]}" -n "${NAMESPACE}" get deploy africa-meals-api >/dev/null 2>&1; then
  if "${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/africa-meals-api -- \
    sh -c "nc -z -w 2 host.k3s.internal ${BOLT_PORT}" 2>/dev/null; then
    log "OK pod API → host.k3s.internal:${BOLT_PORT}"
  else
    warn "Pod API → host.k3s.internal:${BOLT_PORT} — vérifier UFW / NEO4J_URI"
  fi
fi

if [[ "${SKIP_EXPORTER}" != "1" ]]; then
  if [[ -x "${SCRIPT_DIR}/repair-neo4j-exporter-host.sh" ]]; then
    bash "${SCRIPT_DIR}/repair-neo4j-exporter-host.sh"
  else
    warn "repair-neo4j-exporter-host.sh absent — Grafana neo4j_exporter_up peut rester DOWN"
  fi
fi

if [[ "${SKIP_DOCKER_DOWN}" != "1" ]]; then
  log "docker compose down (sans -v)"
  cd "${NEO4J_DIR}"
  compose_neo4j down || true
fi

log "Cutover Neo4j OK"
log "  Browser  http://127.0.0.1:${HTTP_PORT}"
log "  Bolt     bolt://127.0.0.1:${BOLT_PORT}  (API: host.k3s.internal:${BOLT_PORT})"
log "  Public   https://db-graph.wise-eat.com · bolt+s://…:7688"
log "  Docs     : k8s/neo4j/MIGRATE.md"
