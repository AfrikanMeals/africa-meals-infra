#!/usr/bin/env bash
# Répare le scrape Prometheus → EMQX (Grafana EMQX « No data »).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation scrape EMQX → Prometheus ==="

ensure_docker
ensure_wise_eat_infra_network

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-emqx-1$'; then
  warn "EMQX absent — installation"
  bash "${SCRIPT_DIR}/install-emqx.sh"
fi

ensure_emqx_on_wise_eat_infra || die "EMQX injoignable sur wise-eat-infra"

EMQX_DASH_PORT="${EMQX_DASHBOARD_PORT:-18083}"
if [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
  EMQX_DASH_PORT="${EMQX_DASHBOARD_PORT:-18083}"
fi

log "Attente métriques EMQX primary (:${EMQX_DASH_PORT})…"
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${EMQX_DASH_PORT}/api/v5/prometheus/stats" \
    | grep -qE '(^|\n)emqx_'; then
    break
  fi
  sleep 2
done

if ! curl -sf "http://127.0.0.1:${EMQX_DASH_PORT}/api/v5/prometheus/stats" \
  | grep -qE '(^|\n)emqx_connections_count'; then
  warn "Métriques EMQX absentes sur 127.0.0.1:${EMQX_DASH_PORT}"
  docker logs --tail=40 wise-eat-emqx-1 2>&1 || true
  die "EMQX n'expose pas /api/v5/prometheus/stats — vérifier docker logs wise-eat-emqx-1"
fi
log "OK  EMQX primary expose emqx_* sur :${EMQX_DASH_PORT}"

log "Test réseau Docker wise-eat-infra → wise-eat-emqx-1:18083"
if ! docker run --rm --network wise-eat-infra curlimages/curl:8.5.0 \
  -sf --max-time 10 "http://wise-eat-emqx-1:18083/api/v5/prometheus/stats" \
  | grep -q 'emqx_connections_count'; then
  warn "wise-eat-emqx-1 injoignable depuis wise-eat-infra"
  docker network inspect wise-eat-infra --format '{{range .Containers}}{{.Name}} {{end}}' || true
  die "Prometheus ne peut pas joindre wise-eat-emqx-1:18083 — réseau Docker"
fi
log "OK  wise-eat-infra → wise-eat-emqx-1:18083"

sync_component monitoring
cd "${MON_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

docker compose --env-file .env.monitoring up -d prometheus

if ! wait_for_prometheus_ready 60; then
  docker compose --env-file .env.monitoring logs --tail=30 prometheus || true
  die "Prometheus injoignable sur :9090"
fi

if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée"
else
  warn "Reload HTTP indisponible — redémarrage Prometheus"
  docker compose --env-file .env.monitoring restart prometheus
  wait_for_prometheus_ready 60 || die "Prometheus injoignable après restart"
fi

log "Attente scrape Prometheus (20s)…"
sleep 20

prom_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job="emqx"}' || true)"
if [[ -z "${prom_out}" ]]; then
  warn "Prometheus API vide — http://127.0.0.1:9090/targets"
else
  echo "${prom_out}" | python3 -c "
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print('  (réponse vide)'); raise SystemExit(1)
d=json.loads(raw)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (vide — job emqx DOWN dans /targets)')
    raise SystemExit(1)
for s in r:
    m=s.get('metric',{})
    print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
"
fi

conn_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=emqx_connections_count{job=\"emqx\"}' || true)"
if [[ -n "${conn_out}" ]]; then
  echo "${conn_out}" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
print(f'  emqx_connections_count: {len(r)} série(s)')
"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" 2>/dev/null || true
docker compose --env-file .env.monitoring up -d --force-recreate grafana 2>/dev/null || true

log "Terminé — Grafana dossier EMQX → Wise Eat — EMQX"
