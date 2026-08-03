#!/usr/bin/env bash
# Répare le scrape Prometheus → Neo4j (Grafana Neo4j « No data »).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation scrape Neo4j → Prometheus ==="

ensure_docker
ensure_wise_eat_infra_network

# Post-cutover k8s : pod hostPort suffit ; sinon installer Docker legacy.
neo4j_k8s_ready=false
if command -v kubectl >/dev/null 2>&1 || command -v k3s >/dev/null 2>&1; then
  kc=(kubectl)
  command -v kubectl >/dev/null 2>&1 || kc=(sudo k3s kubectl)
  if "${kc[@]}" -n wise-eat get deploy/neo4j >/dev/null 2>&1; then
    neo4j_k8s_ready=true
  fi
fi
if [[ "${neo4j_k8s_ready}" != "true" ]] && ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-neo4j'; then
  warn "Neo4j absent — installation Docker"
  bash "${SCRIPT_DIR}/install-neo4j.sh"
fi
# Exporter vers hostPort (k8s) ou Docker DNS selon présence pod.
if [[ "${neo4j_k8s_ready}" == "true" ]] && [[ -x "${WISE_EAT_ROOT}/k8s/scripts/repair-neo4j-exporter-host.sh" ]]; then
  bash "${WISE_EAT_ROOT}/k8s/scripts/repair-neo4j-exporter-host.sh"
  # Suite = reload Prometheus / vérifs metrics (exporter déjà recréé).
fi

if [[ -f "${NEO4J_ENV}" ]]; then
  source_dotenv "${NEO4J_ENV}"
fi

sync_component monitoring
cd "${MON_DIR}"

if [[ ! -f .env.monitoring ]]; then
  cp .env.example .env.monitoring
  chmod 600 .env.monitoring
fi

sanitize_monitoring_env_file .env.monitoring

# Sync credentials Neo4j → monitoring (exporter Bolt)
if [[ -f "${NEO4J_ENV}" ]]; then
  source_dotenv "${NEO4J_ENV}"
  for key in NEO4J_USER NEO4J_PASSWORD; do
    if [[ -n "${!key:-}" ]]; then
      if grep -q "^${key}=" .env.monitoring 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${!key}|" .env.monitoring
      else
        echo "${key}=${!key}" >> .env.monitoring
      fi
    fi
  done
fi

source_dotenv .env.monitoring

if [[ -z "${NEO4J_PASSWORD:-}" ]]; then
  die "NEO4J_PASSWORD manquant — renseigner neo4j/.env.neo4j puis relancer"
fi

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

COMPOSE_ARGS=(--env-file .env.monitoring)
if [[ -n "$(wise_eat_compose_profiles || true)" ]]; then
  COMPOSE_ARGS+=(--profile cluster-b)
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" 2>/dev/null || true

reconcile_monitoring_compose_named_containers

# k8s : exporter déjà via repair-neo4j-exporter-host (host network + bolt://127.0.0.1).
# Sync URI/listen dans .env.monitoring pour que compose up ne réintroduise pas host.docker.internal.
if [[ "${neo4j_k8s_ready}" == "true" ]]; then
  if ! grep -q '^NEO4J_URI=' .env.monitoring 2>/dev/null; then
    echo 'NEO4J_URI=bolt://127.0.0.1:7687' >> .env.monitoring
  else
    sed -i 's|^NEO4J_URI=.*|NEO4J_URI=bolt://127.0.0.1:7687|' .env.monitoring
  fi
  if ! grep -q '^NEO4J_EXPORTER_LISTEN_ADDRESS=' .env.monitoring 2>/dev/null; then
    echo 'NEO4J_EXPORTER_LISTEN_ADDRESS=127.0.0.1:9217' >> .env.monitoring
  else
    sed -i 's|^NEO4J_EXPORTER_LISTEN_ADDRESS=.*|NEO4J_EXPORTER_LISTEN_ADDRESS=127.0.0.1:9217|' .env.monitoring
  fi
  log "Recréation Prometheus + Grafana (exporter k8s déjà OK)"
  if ! docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate prometheus grafana; then
    docker rm -f wise-eat-prometheus wise-eat-grafana 2>/dev/null || true
    docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate prometheus grafana
  fi
else
  log "Recréation neo4j-exporter + Prometheus + Grafana"
  if ! docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate neo4j-exporter prometheus grafana; then
    docker rm -f wise-eat-prometheus wise-eat-grafana 2>/dev/null || true
    docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate neo4j-exporter prometheus grafana
  fi
fi

if ! wait_for_prometheus_ready 60; then
  docker compose "${COMPOSE_ARGS[@]}" logs --tail=30 prometheus || true
  die "Prometheus injoignable sur :9090"
fi

if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée"
else
  docker compose "${COMPOSE_ARGS[@]}" restart prometheus
  wait_for_prometheus_ready 60 || die "Prometheus injoignable après restart"
fi

sleep 5
if curl -sf http://127.0.0.1:9217/metrics 2>/dev/null | grep -q '^neo4j_exporter_up '; then
  log "OK  neo4j-exporter (:9217) — métriques neo4j_* exposées"
else
  warn "FAIL neo4j-exporter (:9217) — logs :"
  docker logs wise-eat-neo4j-exporter --tail 20 2>&1 | sed 's/^/  /' || true
fi

if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=neo4j_exporter_up{job="neo4j"}' 2>/dev/null \
  | grep -q '"value":\["[^"]*", *"1"\]'; then
  log "OK  Prometheus neo4j_exporter_up=1 (job=neo4j)"
else
  warn "Prometheus neo4j_exporter_up ≠ 1 — attendre le prochain scrape (30s) ou vérifier auth Bolt"
fi

echo ""
log "Grafana : dossier Neo4j → Wise Eat — Neo4j"
echo "  curl -s http://127.0.0.1:9217/metrics | grep '^neo4j_exporter_up '"
echo "  curl -sG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=neo4j_exporter_up{job=\"neo4j\"}'"
