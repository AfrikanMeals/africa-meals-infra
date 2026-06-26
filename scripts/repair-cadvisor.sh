#!/usr/bin/env bash
# Recréer cAdvisor (cgroup v2 + Docker 29 overlayfs) et valider métriques conteneur Grafana.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation cAdvisor (métriques conteneurs Docker) ==="

sync_component monitoring
cd "${MON_DIR}"
ensure_docker
ensure_wise_eat_infra_network

[[ -f .env.monitoring ]] || die "Monitoring absent — sudo ./install.sh monitoring"

COMPOSE_ARGS=(--env-file .env.monitoring)
if [[ -n "$(wise_eat_compose_profiles || true)" ]]; then
  COMPOSE_ARGS+=(--profile cluster-b)
fi

storage_driver="$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')"
log "Storage Driver Docker : ${storage_driver:-inconnu}"
if [[ "${storage_driver}" == "overlayfs" ]]; then
  log "Docker 29 overlayfs — compose utilise --disable_metrics=disk (cadvisor#3860)"
fi

docker compose "${COMPOSE_ARGS[@]}" pull cadvisor
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate cadvisor

if ! wait_for_cadvisor_container_metrics 60; then
  warn "cAdvisor ne remonte pas de métriques par conteneur"
  docker logs wise-eat-cadvisor --tail 25 2>&1 | sed 's/^/  /' || true
  echo ""
  warn "Vérifier : curl -s http://127.0.0.1:8088/metrics | grep container_cpu | grep -v 'id=\"/\"' | head"
  exit 1
fi

curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true

count="$(curl -sf http://127.0.0.1:8088/metrics \
  | grep '^container_cpu_usage_seconds_total' | grep -v 'id="/"' | wc -l | tr -d ' ')"
log "cAdvisor OK — ${count} série(s) container_cpu (hors racine)"
log "Grafana : Wise Eat — Docker Monitoring · Wise Eat — Ollama"
