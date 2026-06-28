#!/usr/bin/env bash
# Corrige le scrape node_exporter (Grafana « node_exporter scrape DOWN »).
#
# Cause fréquente : Prometheus en network_mode=host mais prometheus.yml pointe
# encore vers node-exporter:9100 (DNS Docker injoignable).
#
# Usage : sudo scripts/repair-prometheus-host-targets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MONITORING_DIR="${INFRA_ROOT}/monitoring"
PROM_FILE="${MONITORING_DIR}/prometheus/prometheus.yml"
PROM_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
K8S_SCRIPTS="${INFRA_ROOT}/k8s/scripts"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

prom_query() {
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=${1}" 2>/dev/null || true
}

node_scrape_up() {
  prom_query 'up{job="node",instance="wise-eat:9100"}' | grep -q '"value":\[".*","1"\]'
}

log "=== Réparation scrape node_exporter (Grafana Core System) ==="

if [[ ! -f "${PROM_FILE}" ]]; then
  die "Fichier absent : ${PROM_FILE}"
fi

if grep -qE "targets: \['node-exporter:9100'\]|targets: \['cadvisor:8080'\]" "${PROM_FILE}"; then
  warn "prometheus.yml obsolète (cibles Docker DNS) — git pull requis dans ${INFRA_ROOT}"
  if git -C "${INFRA_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${INFRA_ROOT}" pull --ff-only 2>/dev/null || true
  fi
  if grep -qE "targets: \['node-exporter:9100'\]" "${PROM_FILE}"; then
    die "Toujours node-exporter:9100 — mettre à jour infra puis relancer ce script"
  fi
  log "prometheus.yml corrigé (127.0.0.1:9100)"
fi

if ! curl -sf http://127.0.0.1:9100/metrics 2>/dev/null | grep -q '^node_cpu_seconds_total'; then
  warn "node_exporter :9100 injoignable — démarrage conteneur..."
  ensure_docker
  ensure_wise_eat_infra_network
  cd "${MON_DIR}"
  COMPOSE_ARGS=(--env-file .env.monitoring)
  [[ -n "$(wise_eat_compose_profiles || true)" ]] && COMPOSE_ARGS+=(--profile cluster-b)
  docker compose "${COMPOSE_ARGS[@]}" up -d node-exporter
  sleep 2
  curl -sf http://127.0.0.1:9100/metrics | grep -q '^node_cpu_seconds_total' \
    || die "wise-eat-node-exporter ne répond pas sur :9100"
fi
log "OK node_exporter local :9100"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  warn "Prometheus absent — installation monitoring..."
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

prom_mode="$(docker inspect wise-eat-prometheus -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
if [[ "${prom_mode}" != "host" ]]; then
  warn "Prometheus pas en network_mode=host — migration..."
  [[ -x "${K8S_SCRIPTS}/recreate-prometheus-host.sh" ]] \
    && "${K8S_SCRIPTS}/recreate-prometheus-host.sh" \
    || die "Exécuter : sudo ${K8S_SCRIPTS}/recreate-prometheus-host.sh"
fi

if ! node_scrape_up; then
  log "Recréation Prometheus (montage prometheus.yml à jour)..."
  if [[ -x "${K8S_SCRIPTS}/recreate-prometheus-host.sh" ]]; then
    "${K8S_SCRIPTS}/recreate-prometheus-host.sh"
  else
    cd "${MON_DIR}"
    COMPOSE_ARGS=(--env-file .env.monitoring)
    docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate prometheus
  fi
  sleep 3
fi

if curl -sf -X POST "${PROM_URL}/-/reload" >/dev/null 2>&1; then
  log "Prometheus rechargé (/-/reload)"
else
  docker restart wise-eat-prometheus >/dev/null
  sleep 3
fi

for _ in $(seq 1 20); do
  if node_scrape_up; then
    log "OK up{job=node,instance=wise-eat:9100}=1"
    prom_query 'node_uname_info{job="node",instance="wise-eat:9100"}' \
      | python3 -c "
import json,sys
r=json.load(sys.stdin).get('data',{}).get('result',[])
if r:
    m=r[0].get('metric',{})
    print(f\"  nodename={m.get('nodename','?')} instance={m.get('instance','?')}\")
" 2>/dev/null || true
    echo ""
    log "Grafana : docker restart wise-eat-grafana puis rafraîchir « Wise Eat — System (Node Exporter) »"
    exit 0
  fi
  sleep 2
done

echo "Scrape node toujours DOWN — diagnostic :" >&2
curl -sf "${PROM_URL}/api/v1/targets" 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d.get('data',{}).get('activeTargets',[]):
    if t.get('labels',{}).get('job')=='node':
        print(f\"  job=node health={t.get('health')} url={t.get('scrapeUrl')} error={t.get('lastError','')}\")
" 2>/dev/null || true
exit 1
