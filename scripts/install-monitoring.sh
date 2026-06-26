#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component monitoring
cd "${MON_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.monitoring ]]; then
  cp .env.example .env.monitoring
  chmod 600 .env.monitoring
fi

if [[ -f "${REDIS_ENV}" ]]; then
  set -a && source "${REDIS_ENV}" && set +a
  for key in CACHE_REDIS_PASSWORD BULL_REDIS_PASSWORD; do
    if [[ -n "${!key:-}" ]]; then
      if grep -q "^${key}=" .env.monitoring; then
        sed -i "s|^${key}=.*|${key}=${!key}|" .env.monitoring
      else
        echo "${key}=${!key}" >> .env.monitoring
      fi
    fi
  done
fi

MEMCACHED_ENV="${MEMCACHED_DIR}/.env.memcached"
if [[ -f "${MEMCACHED_ENV}" ]]; then
  set -a && source "${MEMCACHED_ENV}" && set +a
  port="${MEMCACHED_PORT:-11211}"
  if grep -q '^MEMCACHED_PORT=' .env.monitoring; then
    sed -i "s|^MEMCACHED_PORT=.*|MEMCACHED_PORT=${port}|" .env.monitoring
  else
    echo "MEMCACHED_PORT=${port}" >> .env.monitoring
  fi
fi

if [[ -f "${MONGODB_ENV}" ]]; then
  set -a && source "${MONGODB_ENV}" && set +a
  for key in MONGO_ROOT_USER MONGO_ROOT_PASSWORD MONGO_REPLICA_SET; do
    if [[ -n "${!key:-}" ]]; then
      if grep -q "^${key}=" .env.monitoring 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${!key}|" .env.monitoring
      else
        echo "${key}=${!key}" >> .env.monitoring
      fi
    fi
  done
fi

set -a && source .env.monitoring && set +a

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}|" .env.monitoring
  log "Mot de passe Grafana généré → ${MON_DIR}/.env.monitoring"
fi

if [[ -z "${PROMETHEUS_BASIC_AUTH_PASSWORD:-}" ]]; then
  PROMETHEUS_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  if grep -q '^PROMETHEUS_BASIC_AUTH_PASSWORD=' .env.monitoring; then
    sed -i "s|^PROMETHEUS_BASIC_AUTH_PASSWORD=.*|PROMETHEUS_BASIC_AUTH_PASSWORD=${PROMETHEUS_BASIC_AUTH_PASSWORD}|" .env.monitoring
  else
    echo "PROMETHEUS_BASIC_AUTH_PASSWORD=${PROMETHEUS_BASIC_AUTH_PASSWORD}" >> .env.monitoring
  fi
  log "Mot de passe Prometheus (nginx basic auth) généré → ${MON_DIR}/.env.monitoring"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh"

remove_legacy_monitoring_exporter_containers

COMPOSE_ARGS=(--env-file .env.monitoring)
if [[ -n "$(wise_eat_compose_profiles || true)" ]]; then
  COMPOSE_ARGS+=(--profile cluster-b)
  log "Monitoring réplicas : Redis :9123/:9125/:9124/:9126 Memcached :9151/:9152"
fi
log "Core System : node_exporter :9100 + cAdvisor :8088 (dashboards #1860 / #4271)"

docker compose "${COMPOSE_ARGS[@]}" pull
docker compose "${COMPOSE_ARGS[@]}" up -d --remove-orphans
sleep 5

docker compose "${COMPOSE_ARGS[@]}" ps
echo ""

if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée"
else
  warn "Prometheus reload HTTP indisponible — redémarrage conteneur"
  docker compose "${COMPOSE_ARGS[@]}" restart prometheus
  sleep 3
fi

bash "${SCRIPT_DIR}/verify-monitoring.sh" || true

echo ""
log "Métriques Redis : curl -s http://127.0.0.1:9121/metrics | grep '^redis_up '"
log "Métriques Memcached : curl -s http://127.0.0.1:9150/metrics | grep '^memcached_up '"
log "Grafana   : https://console.wise-eat.com (ou tunnel SSH → :3000)"
log "Prometheus: https://logs.wise-eat.com (basic auth — voir .env.monitoring)"
log "Dashboards : Redis · Memcached · MinIO · EMQX · MongoDB · Ollama (#25086)"
