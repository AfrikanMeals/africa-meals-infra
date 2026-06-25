#!/usr/bin/env bash
# Répare exporters Prometheus (redis_up / memcached_up) après changement réseau ou mots de passe.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation stack monitoring ==="

# Évite conflits git sur dashboards régénérés par fetch-grafana-dashboard.sh
if git -C "${INFRA_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git -C "${INFRA_ROOT}" diff --quiet -- \
    "monitoring/grafana/dashboards/Core System/docker-monitoring.json" 2>/dev/null; then
    warn "docker-monitoring.json modifié localement — reset pour aligner sur le dépôt"
    git -C "${INFRA_ROOT}" checkout -- \
      "monitoring/grafana/dashboards/Core System/docker-monitoring.json" 2>/dev/null || true
  fi
  if git -C "${INFRA_ROOT}" pull --ff-only 2>/dev/null; then
    log "git pull OK (${INFRA_ROOT})"
  else
    warn "git pull échoué — ex. cd ${INFRA_ROOT} && git checkout -- monitoring/... && git pull"
  fi
fi

ensure_docker
ensure_wise_eat_infra_network

redis_running() {
  docker ps --format '{{.Names}}' | grep -q '^wise-eat-redis-cache$'
}

if redis_running; then
  log "Redis cache : OK"
else
  warn "Redis cache absent — installation Redis"
  bash "${SCRIPT_DIR}/install-redis.sh"
fi

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-node-exporter$'; then
  warn "node_exporter absent — relance monitoring"
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-cadvisor$'; then
  warn "cAdvisor absent — relance monitoring"
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

if docker ps --format '{{.Names}}' | grep -q '^wise-eat-memcached$'; then
  log "Memcached : OK"
else
  warn "Memcached absent — installation Memcached"
  bash "${SCRIPT_DIR}/install-memcached.sh"
fi

if docker ps --format '{{.Names}}' | grep -q '^wise-eat-minio$'; then
  log "MinIO : OK"
  ensure_minio_on_wise_eat_infra || \
    warn "MinIO hors wise-eat-infra — sudo ./install.sh repair-minio-prometheus"
else
  warn "MinIO absent — installation MinIO (métriques Grafana)"
  bash "${SCRIPT_DIR}/install-minio.sh"
fi

bash "${SCRIPT_DIR}/install-monitoring.sh"

cd "${MON_DIR}"
COMPOSE_ARGS=(--env-file .env.monitoring)
if [[ -n "$(wise_eat_compose_profiles || true)" ]]; then
  COMPOSE_ARGS+=(--profile cluster-b)
fi
log "Recréation cAdvisor (métriques conteneurs)…"
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate cadvisor
sleep 8

if ! bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh"; then
  warn "fetch-grafana-dashboard partiellement échoué — vérifier python3 / curl"
fi

log "Attente démarrage Prometheus (15s max)…"
for _ in $(seq 1 15); do
  if curl -sf 'http://127.0.0.1:9090/-/ready' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo ""
log "Diagnostic :"
bash "${SCRIPT_DIR}/verify-monitoring.sh" || true

if ! redis_running; then
  echo ""
  warn "Redis toujours arrêté — vérifier : cd ${REDIS_DIR} && docker compose ps && docker compose logs --tail=30"
fi
