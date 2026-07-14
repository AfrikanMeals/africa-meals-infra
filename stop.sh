#!/usr/bin/env bash
# Wise Eat — arrêt infra VPS par composant (miroir de install.sh).
#
# Usage:
#   sudo ./stop.sh redis
#   sudo ./stop.sh neo4j monitoring
#   sudo ./stop.sh --list
#   sudo ./stop.sh --help
#
# Les volumes / données ne sont PAS supprimés (docker compose stop|down sans -v).
# Relancer : sudo ./install.sh <composant>
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

usage() {
  cat <<EOF
Wise Eat — arrêt infra VPS (par composant)

Usage:
  sudo $0 <composant> [composant...]
  sudo $0 --list
  sudo $0 --help

Composants Docker (compose stop / down, données conservées) :
  redis         Redis cache + BullMQ (+ réplicas)
  memcached     Memcached (+ réplicas)
  minio         MinIO S3
  emqx          EMQX MQTT cluster
  mongodb       MongoDB rs0 (+ DbGate)
  ollama        Ollama
  neo4j         Neo4j Community
  matomo        Matomo + MariaDB
  monitoring    Prometheus / Grafana / exporters

Composants systemd / host :
  haproxy       HAProxy TLS TCP
  stunnel       Stunnel TLS (legacy Redis)
  nginx         nginx (⚠️ coupe api/ws/TLS publics)
  apache        apache2

Composants k3s (scale replicas → 0) :
  k8s-api       deployment/africa-meals-api
  k8s-ws        deployment/africa-meals-ws
  api           alias k8s-api
  ws            alias k8s-ws

Exemples:
  sudo $0 neo4j
  sudo $0 redis memcached
  sudo $0 monitoring
  sudo $0 k8s-api

Relancer ensuite :
  sudo ./install.sh neo4j
  sudo k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod

Env:
  WISE_EAT_ROOT=${WISE_EAT_ROOT:-$INFRA_ROOT}
  STOP_MODE=stop|down   (défaut: stop — conteneurs arrêtés mais non supprimés ;
                         down = compose down --remove-orphans, volumes intacts)
EOF
}

list_components() {
  cat <<EOF
redis
memcached
minio
emqx
mongodb
ollama
neo4j
matomo
monitoring
haproxy
stunnel
nginx
apache
k8s-api
k8s-ws
api
ws
EOF
}

# STOP_MODE=stop (défaut) | down
STOP_MODE="${STOP_MODE:-stop}"

compose_halt() {
  local dir="$1"
  local env_file="${2:-}"
  shift 2 || true
  local extra_projects=("$@")

  if [[ ! -d "${dir}" ]]; then
    warn "Dossier absent : ${dir} — skip"
    return 0
  fi
  if [[ ! -f "${dir}/docker-compose.yml" ]] && [[ ! -f "${dir}/compose.yml" ]]; then
    warn "Pas de docker-compose.yml dans ${dir} — skip"
    return 0
  fi

  local args=()
  if [[ -n "${env_file}" && -f "${env_file}" ]]; then
    args+=(--env-file "${env_file}")
  elif [[ -n "${env_file}" ]]; then
    warn "Env manquant ${env_file} — compose sans --env-file"
  fi

  (
    cd "${dir}"
    if [[ "${STOP_MODE}" == "down" ]]; then
      log "docker compose down (volumes conservés) — ${dir}"
      docker compose "${args[@]}" down --remove-orphans 2>/dev/null || true
      local p
      for p in "${extra_projects[@]+"${extra_projects[@]}"}"; do
        [[ -z "${p}" ]] && continue
        docker compose -p "${p}" "${args[@]}" down --remove-orphans 2>/dev/null || true
      done
    else
      log "docker compose stop — ${dir}"
      docker compose "${args[@]}" stop 2>/dev/null || true
      local p
      for p in "${extra_projects[@]+"${extra_projects[@]}"}"; do
        [[ -z "${p}" ]] && continue
        docker compose -p "${p}" "${args[@]}" stop 2>/dev/null || true
      done
    fi
  )
}

systemctl_halt() {
  local unit="$1"
  if systemctl list-unit-files "${unit}.service" &>/dev/null \
    || systemctl cat "${unit}.service" &>/dev/null; then
    log "systemctl stop ${unit}"
    systemctl stop "${unit}" 2>/dev/null || true
  else
    warn "Unit systemd absente : ${unit}.service — skip"
  fi
}

k8s_scale_zero() {
  local deploy="$1"
  local ns="${2:-wise-eat}"
  local kubectl=(k3s kubectl)
  if ! command -v k3s >/dev/null 2>&1; then
    warn "k3s absent — skip ${deploy}"
    return 0
  fi
  if ! "${kubectl[@]}" get deployment "${deploy}" -n "${ns}" &>/dev/null; then
    warn "Deployment ${ns}/${deploy} introuvable — skip"
    return 0
  fi
  log "kubectl scale ${ns}/${deploy} --replicas=0"
  "${kubectl[@]}" scale deployment/"${deploy}" -n "${ns}" --replicas=0
  "${kubectl[@]}" rollout status deployment/"${deploy}" -n "${ns}" --timeout=120s 2>/dev/null || true
}

stop_component() {
  local name="$1"
  case "${name}" in
    redis)
      compose_halt "${REDIS_DIR}" "${REDIS_ENV}"
      ;;
    memcached)
      if [[ -f "${MEMCACHED_DIR}/.env.memcached" ]]; then
        compose_halt "${MEMCACHED_DIR}" "${MEMCACHED_DIR}/.env.memcached"
      else
        compose_halt "${MEMCACHED_DIR}" ""
      fi
      ;;
    minio)
      compose_halt "${MINIO_DIR}" "${MINIO_ENV}"
      ;;
    emqx)
      compose_halt "${EMQX_DIR}" "${EMQX_ENV}" emqx wise-eat-emqx
      ;;
    mongodb|mongo)
      compose_halt "${MONGODB_DIR}" "${MONGODB_ENV}" wise-eat-mongo
      ;;
    ollama)
      if [[ -f "${OLLAMA_DIR}/.env.ollama" ]]; then
        compose_halt "${OLLAMA_DIR}" "${OLLAMA_DIR}/.env.ollama"
      else
        compose_halt "${OLLAMA_DIR}" ""
      fi
      ;;
    neo4j)
      compose_halt "${NEO4J_DIR}" "${NEO4J_ENV}"
      ;;
    matomo)
      compose_halt "${MATOMO_DIR}" "${MATOMO_ENV}" wise-eat-matomo
      ;;
    monitoring|monitor)
      if [[ -f "${MON_DIR}/.env.monitoring" ]]; then
        compose_halt "${MON_DIR}" "${MON_DIR}/.env.monitoring"
      else
        compose_halt "${MON_DIR}" ""
      fi
      ;;
    haproxy)
      systemctl_halt haproxy
      ;;
    stunnel)
      systemctl_halt stunnel4
      stunnel_stop_all 2>/dev/null || true
      ;;
    nginx)
      warn "Arrêt nginx — sites publics (api/ws/TLS) indisponibles"
      systemctl_halt nginx
      ;;
    apache|apache2)
      warn "Arrêt apache2 — sites publics indisponibles"
      systemctl_halt apache2
      ;;
    k8s-api|api|africa-meals-api)
      k8s_scale_zero africa-meals-api wise-eat
      ;;
    k8s-ws|ws|africa-meals-ws)
      k8s_scale_zero africa-meals-ws wise-eat
      ;;
    *)
      die "Composant inconnu : ${name} (voir $0 --list)"
      ;;
  esac
  log "OK — arrêté : ${name}"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "${1}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    -l|--list|list)
      list_components
      exit 0
      ;;
  esac

  require_root

  if [[ "${STOP_MODE}" != "stop" && "${STOP_MODE}" != "down" ]]; then
    die "STOP_MODE doit être stop ou down (reçu: ${STOP_MODE})"
  fi

  local c
  for c in "$@"; do
    stop_component "${c}"
  done

  log "Terminé. Relancer un composant : sudo ./install.sh <composant>"
}

main "$@"
