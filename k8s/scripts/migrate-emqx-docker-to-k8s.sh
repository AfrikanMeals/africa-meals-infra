#!/usr/bin/env bash
# Cutover EMQX Docker Compose → pods k3s (hostPath Mnesia + hostPort primary).
#
# GARDE-FOUS :
#   - Pas de docker compose down -v
#   - hostPath = /opt/wise-eat/emqx/data-emqx-{1,2,3} (mêmes dossiers Docker)
#   - Node names emqx@wise-eat-emqx-{1,2,3} + cookie .env.emqx inchangés (cluster Mnesia)
#   - Primary hostPort 1883/8083/18083 — nginx MQTTS/WSS + dashboard inchangés
#   - API/WS restent sur mqtts://host.k3s.internal:8883 (nginx → 127.0.0.1:1883)
#
# Usage :
#   sudo ./migrate-emqx-docker-to-k8s.sh
#   sudo ./migrate-emqx-docker-to-k8s.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EMQX_DIR="${EMQX_DIR:-${INFRA_ROOT}/emqx}"
EMQX_KUSTOMIZE="${INFRA_ROOT}/k8s/emqx"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
SKIP_DOCKER_DOWN="${SKIP_DOCKER_DOWN:-0}"
SKIP_PROMETHEUS="${SKIP_PROMETHEUS:-0}"
SKIP_AUTH="${SKIP_AUTH:-0}"
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo migrate-emqx-docker-to-k8s.sh [--dry-run]

  1. Pré-checks volumes data-emqx-* + .env.emqx
  2. Backup tar data-emqx-* (sauf SKIP_BACKUP=1)
  3. create-emqx-secret.sh (cookie + dashboard)
  4. docker compose stop (libère hostPort 1883/8083/18083)
  5. kubectl apply -k k8s/emqx (primary puis réplicas)
  6. Health /api/v5/status + cluster status
  7. bootstrap-emqx-auth + sync Prometheus réplicas (pod IPs)
  8. docker compose down (sans -v)

Rollback : k8s/emqx/MIGRATE.md
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

emqx_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^wise-eat-emqx-[123]$'
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

# Health dashboard EMQX (hostPort primary).
wait_emqx_status() {
  local port="$1" label="$2" i
  for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${port}/api/v5/status" >/dev/null 2>&1; then
      log "OK health ${label} :127.0.0.1:${port}/api/v5/status"
      return 0
    fi
    sleep 3
  done
  return 1
}

compose_emqx() {
  docker compose --env-file .env.emqx "$@"
}

[[ -f "${EMQX_DIR}/.env.emqx" ]] || die "Absent ${EMQX_DIR}/.env.emqx — sudo ./install.sh emqx d'abord"
[[ -d "${EMQX_KUSTOMIZE}" ]] || die "Absent ${EMQX_KUSTOMIZE}"

set -a && source "${EMQX_DIR}/.env.emqx" && set +a
: "${EMQX_ERLANG_COOKIE:?}"
: "${EMQX_DASHBOARD_PASSWORD:?}"
MQTT_PORT="${EMQX_MQTT_PORT:-1883}"
WS_PORT="${EMQX_WS_PORT:-8083}"
DASH_PORT="${EMQX_DASHBOARD_PORT:-18083}"

DATA_DIRS=(data-emqx-1 data-emqx-2 data-emqx-3)
cd "${EMQX_DIR}"
for d in "${DATA_DIRS[@]}"; do
  [[ -d "${d}" ]] || die "Volume absent ${EMQX_DIR}/${d}"
done

if ! command -v "${KUBECTL[0]}" >/dev/null 2>&1 && [[ "${KUBECTL[0]}" != "sudo" ]]; then
  die "kubectl / k3s kubectl introuvable"
fi
command -v nc >/dev/null 2>&1 || die "nc (netcat) requis"
command -v curl >/dev/null 2>&1 || die "curl requis"

log "EMQX cutover Docker → k8s (ports ${MQTT_PORT}/${WS_PORT}/${DASH_PORT})"
log "Volumes : ${EMQX_DIR}/data-emqx-{1,2,3} — cookie/dashboard depuis .env.emqx"
log "API/WS : mqtts host.k3s.internal:8883 (nginx) inchangé"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] secret + stop compose + apply -k k8s/emqx + prometheus targets"
  "${KUBECTL[@]}" kustomize "${EMQX_KUSTOMIZE}" | head -50
  exit 0
fi

# 1. UFW (1883 si pods scrapent host — optionnel mais safe)
if [[ -x "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" ]]; then
  bash "${INFRA_ROOT}/scripts/ufw-allow-k3s-pods.sh" || warn "ufw-allow-k3s-pods non bloquant"
fi

# 2. Backup tar (tolère fichiers mutables pendant écriture)
if [[ "${SKIP_BACKUP}" != "1" ]]; then
  BACKUP_DIR="${EMQX_DIR}/backups"
  mkdir -p "${BACKUP_DIR}"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/emqx-data-${STAMP}.tar.gz"
  log "Backup → ${BACKUP_FILE}"
  # Stop d'abord pour AOF/Mnesia cohérent (comme Redis).
  if emqx_docker_running; then
    log "Stop Docker EMQX avant backup…"
    compose_emqx stop
  fi
  set +e
  tar -czf "${BACKUP_FILE}" -C "${EMQX_DIR}" "${DATA_DIRS[@]}" 2>/tmp/emqx-tar.err
  tar_rc=$?
  set -e
  if [[ "${tar_rc}" -gt 1 ]]; then
    cat /tmp/emqx-tar.err >&2 || true
    die "Backup tar échoué (rc=${tar_rc})"
  fi
  [[ -s "${BACKUP_FILE}" ]] || die "Backup vide"
  log "Backup OK ($(du -h "${BACKUP_FILE}" | awk '{print $1}'))"
else
  if emqx_docker_running; then
    log "Stop Docker EMQX (SKIP_BACKUP=1)…"
    compose_emqx stop
  else
    log "Aucun conteneur EMQX Docker Up — reprise mid-cutover"
  fi
fi

for port in "${MQTT_PORT}" "${WS_PORT}" "${DASH_PORT}"; do
  if ! wait_port_free "${port}"; then
    die "Port :${port} encore occupé — docker ps | grep emqx ; ss -tlnp | grep ${port}"
  fi
  log "Port libre :${port}"
done

if emqx_docker_running; then
  die "Conteneur EMQX Docker encore Up — abort"
fi

# 3. Ownership volumes (UID image EMQX)
chown -R 1000:1000 \
  "${EMQX_DIR}/data-emqx-1" \
  "${EMQX_DIR}/data-emqx-2" \
  "${EMQX_DIR}/data-emqx-3" || warn "chown 1000 data-emqx-* non bloquant"

# 4. Secret + apply
bash "${SCRIPT_DIR}/create-emqx-secret.sh"

log "kubectl apply -k k8s/emqx"
"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
# Primary d'abord (évite réplicas orphelines trop longtemps).
"${KUBECTL[@]}" apply -f "${EMQX_KUSTOMIZE}/service-emqx-1.yaml"
"${KUBECTL[@]}" apply -f "${EMQX_KUSTOMIZE}/service-emqx-2.yaml"
"${KUBECTL[@]}" apply -f "${EMQX_KUSTOMIZE}/service-emqx-3.yaml"
"${KUBECTL[@]}" apply -f "${EMQX_KUSTOMIZE}/deployment-emqx-1.yaml"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/emqx-1 --timeout=240s
wait_emqx_status "${DASH_PORT}" "primary" || die "Primary dashboard :${DASH_PORT} pas prêt"

"${KUBECTL[@]}" apply -f "${EMQX_KUSTOMIZE}/deployment-emqx-2.yaml"
"${KUBECTL[@]}" apply -f "${EMQX_KUSTOMIZE}/deployment-emqx-3.yaml"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/emqx-2 --timeout=240s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/emqx-3 --timeout=240s

# 5. Cluster status via ctl dans le pod primary
log "Vérification cluster EMQX…"
sleep 8
CLUSTER_OUT="$("${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/emqx-1 -- \
  /opt/emqx/bin/emqx ctl cluster status 2>/dev/null || true)"
echo "${CLUSTER_OUT}" | sed 's/^/[emqx] /'
# Attendu : 3 nœuds running (tolère formation lente).
if echo "${CLUSTER_OUT}" | grep -qiE 'running.*emqx@wise-eat-emqx'; then
  log "Cluster EMQX répond (ctl)"
else
  warn "Cluster statut ambigu — vérifier logs + DNS wise-eat-emqx-{1,2,3}"
fi

# 6. Auth MQTT (API dashboard hostPort)
if [[ "${SKIP_AUTH}" != "1" ]]; then
  if [[ -x "${INFRA_ROOT}/scripts/bootstrap-emqx-auth.sh" ]]; then
    bash "${INFRA_ROOT}/scripts/bootstrap-emqx-auth.sh" || warn "bootstrap-emqx-auth non bloquant"
  fi
fi

# 7. Prometheus file_sd réplicas → pod IPs k8s
if [[ "${SKIP_PROMETHEUS}" != "1" ]]; then
  if [[ -x "${INFRA_ROOT}/scripts/sync-emqx-prometheus-targets.sh" ]]; then
    bash "${INFRA_ROOT}/scripts/sync-emqx-prometheus-targets.sh" || warn "sync prometheus EMQX non bloquant"
  fi
fi

# 8. Smoke MQTT plaintext local (nginx TLS reste séparé)
if command -v mosquitto_sub >/dev/null 2>&1 && [[ -n "${MQTT_BROKER_PASSWORD:-}" ]]; then
  if timeout 5 mosquitto_sub -h 127.0.0.1 -p "${MQTT_PORT}" \
    -u wise-eat-mqtt -P "${MQTT_BROKER_PASSWORD}" -t '\$SYS/brokers/+/version' -C 1 2>/dev/null \
    | grep -q .; then
    log "OK mosquitto_sub → :${MQTT_PORT}"
  else
    warn "mosquitto_sub :${MQTT_PORT} — vérifier users MQTT / bootstrap-emqx-auth"
  fi
else
  log "Skip mosquitto_sub (binaire absent ou MQTT_BROKER_PASSWORD vide)"
fi

# 9. Retirer Compose (pas -v)
if [[ "${SKIP_DOCKER_DOWN}" != "1" ]]; then
  log "docker compose down (sans -v)"
  cd "${EMQX_DIR}"
  compose_emqx down || true
fi

log "Cutover EMQX OK"
log "  Primary  127.0.0.1:${MQTT_PORT} / :${WS_PORT} / dashboard :${DASH_PORT}"
log "  TLS      mqtts://broker…:${EMQX_MQTTS_PORT:-8883} (nginx → 127.0.0.1:${MQTT_PORT})"
log "  Pods     kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=emqx"
log "  Docs     : k8s/emqx/MIGRATE.md"
