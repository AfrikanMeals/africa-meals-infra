#!/usr/bin/env bash
# Répare le scrape Prometheus → MongoDB (Grafana MongoDB « No data »).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation scrape MongoDB → Prometheus ==="

ensure_docker
ensure_wise_eat_infra_network

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-mongo-1$'; then
  warn "MongoDB absent — installation"
  bash "${SCRIPT_DIR}/install-mongodb.sh"
fi

ensure_mongodb_on_wise_eat_infra || die "MongoDB injoignable sur wise-eat-infra"

if [[ -f "${MONGODB_ENV}" ]]; then
  set -a && source "${MONGODB_ENV}" && set +a
fi

probe_mongo_metrics() {
  docker run --rm --network wise-eat-infra curlimages/curl:8.5.0 \
    -sf --max-time 10 "http://${1}/metrics" 2>/dev/null \
    | grep -q '^mongodb_up '
}

log "Test métriques MongoDB exporter"
if ! curl -sf http://127.0.0.1:9216/metrics 2>/dev/null | grep -q '^mongodb_up '; then
  warn "Exporter local :9216 absent — relance monitoring"
fi

if probe_mongo_metrics "wise-eat-mongodb-exporter:9216"; then
  log "OK  wise-eat-infra → wise-eat-mongodb-exporter:9216"
else
  warn "FAIL wise-eat-infra → wise-eat-mongodb-exporter:9216"
fi

sync_component monitoring
cd "${MON_DIR}"

if [[ -f "${MONGODB_ENV}" ]]; then
  for key in MONGO_ROOT_USER MONGO_ROOT_PASSWORD; do
    if [[ -n "${!key:-}" ]]; then
      if grep -q "^${key}=" .env.monitoring 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${!key}|" .env.monitoring
      else
        echo "${key}=${!key}" >> .env.monitoring
      fi
    fi
  done
fi

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

COMPOSE_ARGS=(--env-file .env.monitoring)
if [[ -n "$(wise_eat_compose_profiles || true)" ]]; then
  COMPOSE_ARGS+=(--profile cluster-b)
fi

log "Recréation mongodb-exporter + Prometheus"
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate mongodb-exporter prometheus

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

log "Attente scrape Prometheus (25s)…"
sleep 25

prom_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job="mongodb"}' || true)"
if [[ -n "${prom_out}" ]]; then
  echo "${prom_out}" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
if not r:
    print('  (vide — job mongodb absent)'); raise SystemExit(1)
for s in r:
    m=s.get('metric',{})
    print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
" || warn "Scrape MongoDB DOWN — vérifier http://127.0.0.1:9090/targets"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" 2>/dev/null || true
docker compose "${COMPOSE_ARGS[@]}" up -d grafana 2>/dev/null || true

log "Terminé — Grafana MongoDB : up{job=\"mongodb\"} doit être 1"
