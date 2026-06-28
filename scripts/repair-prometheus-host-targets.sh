#!/usr/bin/env bash
# Corrige le scrape Prometheus host (node_exporter, cadvisor, redis, …).
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

node_fail=0

log "=== Réparation scrape Prometheus host ==="

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

if node_exporter_metrics_ok; then
  log "OK node_exporter local :9100"
elif ensure_node_exporter; then
  log "OK node_exporter recréé :9100"
else
  warn "node_exporter :9100 KO — on continue Prometheus/Grafana"
  node_fail=1
fi

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  warn "Prometheus absent — installation monitoring..."
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

ensure_prometheus_ready || die "Prometheus indisponible"

if ! node_scrape_up; then
  log "Recréation Prometheus (montage prometheus.yml à jour)..."
  if [[ -x "${K8S_SCRIPTS}/recreate-prometheus-host.sh" ]]; then
    "${K8S_SCRIPTS}/recreate-prometheus-host.sh"
  else
    cd "${MON_DIR}"
    monitoring_compose_args
    docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --force-recreate prometheus
  fi
  sleep 3
  curl -sf -X POST "${PROM_URL}/-/reload" >/dev/null 2>&1 \
    || docker restart wise-eat-prometheus >/dev/null 2>&1 || true
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
    log "Pour Grafana N/A partout : sudo ${SCRIPT_DIR}/repair-grafana-stack.sh"
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

if [[ "${node_fail}" -eq 1 ]]; then
  warn "node_exporter à réparer manuellement — stack Prometheus/Grafana peut quand même fonctionner"
  warn "  sudo ${SCRIPT_DIR}/repair-grafana-stack.sh"
fi
exit 1
