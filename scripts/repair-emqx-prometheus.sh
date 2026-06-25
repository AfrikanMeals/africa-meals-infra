#!/usr/bin/env bash
# Répare le scrape Prometheus → EMQX (Grafana EMQX « No data » / scrape DOWN).
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

ensure_emqx_prometheus_collectors

probe_emqx_metrics() {
  local target="$1"
  docker run --rm --network wise-eat-infra curlimages/curl:8.5.0 \
    -sf --max-time 10 "http://${target}/api/v5/prometheus/stats" 2>/dev/null \
    | grep -q 'emqx_connections_count'
}

log "Test métriques EMQX (host + réseau Docker)"
if ! curl -sf "http://127.0.0.1:${EMQX_DASH_PORT}/api/v5/prometheus/stats" \
  | grep -q 'emqx_connections_count'; then
  docker logs --tail=30 wise-eat-emqx-1 2>&1 || true
  die "EMQX primary n'expose pas /api/v5/prometheus/stats sur :${EMQX_DASH_PORT}"
fi
log "OK  host → 127.0.0.1:${EMQX_DASH_PORT}"

for n in 1 2 3; do
  target="wise-eat-emqx-${n}:18083"
  if probe_emqx_metrics "${target}"; then
    log "OK  wise-eat-infra → ${target}"
  else
    warn "FAIL wise-eat-infra → ${target} (Prometheus target DOWN)"
  fi
done

sync_component monitoring
cd "${MON_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

if ! docker inspect wise-eat-prometheus --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
  | grep -q 'wise-eat-infra'; then
  log "Connexion wise-eat-prometheus → wise-eat-infra"
  docker network connect wise-eat-infra wise-eat-prometheus || true
fi

log "Recréation Prometheus (config emqx job)"
docker compose --env-file .env.monitoring up -d --force-recreate prometheus

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

log "Test scrape depuis conteneur Prometheus (retry 30s)"
scrape_ok=0
for _ in $(seq 1 6); do
  if docker exec wise-eat-prometheus wget -qO- -T 8 \
    'http://wise-eat-emqx-1:18083/api/v5/prometheus/stats' 2>/dev/null \
    | grep -q 'emqx_connections_count'; then
    log "OK  wise-eat-prometheus → wise-eat-emqx-1:18083"
    scrape_ok=1
    break
  fi
  sleep 5
done
if [[ "${scrape_ok}" -eq 0 ]]; then
  warn "FAIL wise-eat-prometheus → wise-eat-emqx-1:18083"
  docker network inspect wise-eat-infra --format '{{range .Containers}}{{.Name}} {{end}}' || true
fi

log "Attente scrape Prometheus (25s)…"
sleep 25

prom_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job="emqx"}' || true)"
if [[ -z "${prom_out}" ]]; then
  die "Prometheus API vide — voir http://127.0.0.1:9090/targets"
fi

echo "${prom_out}" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
if not r:
    print('  (vide — job emqx absent)'); raise SystemExit(1)
ups=[float(s.get('value',[0,0])[1]) for s in r]
for s in r:
    m=s.get('metric',{})
    print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
print(f'  max(up)={max(ups) if ups else 0} count(up=1)={sum(1 for u in ups if u==1)}/{len(ups)}')
if max(ups) < 1:
    raise SystemExit(1)
"

conn_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=emqx_connections_count{job="emqx"}' || true)"
if [[ -n "${conn_out}" ]]; then
  echo "${conn_out}" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
print(f'  emqx_connections_count: {len(r)} série(s)')
if not r:
    raise SystemExit(1)
"
fi

log "Vérification métriques Erlang / Mnesia sur primary"
metrics_sample="$(emqx_fetch_prometheus_stats "${EMQX_DASH_PORT}")"
for needle in erlang_vm_process_count erlang_mnesia_memory_usage_bytes erlang_vm_threads emqx_vm_total_memory; do
  if emqx_prometheus_metric_present "${needle}" "${metrics_sample}"; then
    log "OK  métrique ${needle}"
  else
    warn "ABSENT ${needle} — attente supplémentaire…"
  fi
done

if ! emqx_prometheus_metric_present erlang_vm_process_count "${metrics_sample}"; then
  if wait_for_emqx_prometheus_metrics "${EMQX_DASH_PORT}" 36 \
    erlang_vm_process_count erlang_mnesia_memory_usage_bytes erlang_vm_threads emqx_vm_total_memory; then
    metrics_sample="$(emqx_fetch_prometheus_stats "${EMQX_DASH_PORT}")"
    for needle in erlang_vm_process_count erlang_mnesia_memory_usage_bytes erlang_vm_threads emqx_vm_total_memory; do
      if emqx_prometheus_metric_present "${needle}" "${metrics_sample}"; then
        log "OK  métrique ${needle}"
      else
        warn "ABSENT ${needle} — vérifier EMQX_PROMETHEUS__*_COLLECTOR dans docker-compose.yml"
      fi
    done
  else
    warn "Métriques Erlang / Mnesia toujours absentes — relancer avec EMQX_FORCE_RECREATE=1 si besoin"
  fi
fi

if emqx_api_responds "${EMQX_DASH_PORT}" && command -v nginx >/dev/null 2>&1; then
  log "EMQX dashboard OK — reload nginx (worker.wise-eat.com)"
  nginx_test_and_reload || warn "nginx reload échoué — sudo ./install.sh emqx-worker"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" 2>/dev/null || true
docker compose --env-file .env.monitoring up -d grafana 2>/dev/null || true

log "Terminé — Grafana EMQX : max(up{job=\"emqx\"}) doit être 1 (au moins 1 nœud scrapé)"
