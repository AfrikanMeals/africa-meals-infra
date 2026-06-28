#!/usr/bin/env bash
# Répare Grafana N/A partout : exporters → Prometheus (host) → datasource Grafana.
#
# Cause fréquente après deploy API/k8s :
#   - Grafana pas en network_mode=host → datasource 127.0.0.1:9090 injoignable
#   - prometheus.yml obsolète (cibles Docker DNS) → aucune série
#   - node_exporter conteneur zombie (:9100 down)
#
# Usage : sudo scripts/repair-grafana-stack.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_SCRIPTS="${INFRA_ROOT}/k8s/scripts"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

fail=0

log "=== Réparation stack Grafana (N/A partout) ==="

if git -C "${INFRA_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${INFRA_ROOT}" pull --ff-only 2>/dev/null && log "git pull OK" || warn "git pull échoué — continuer"
fi

echo ""
log "== 1/7 Exporters host (node_exporter, cAdvisor, redis, …) =="
ensure_docker
ensure_wise_eat_infra_network
cd "${MON_DIR}"
monitoring_compose_args
docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --remove-orphans \
  node-exporter cadvisor redis-exporter-cache redis-exporter-bullmq memcached-exporter \
  ollama-exporter mongodb-exporter 2>/dev/null \
  || docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --remove-orphans

if ! node_exporter_metrics_ok; then
  ensure_node_exporter || {
    warn "node_exporter :9100 toujours KO — dashboards Core System vides"
    fail=1
  }
fi

echo ""
log "== 1b/7 cAdvisor (Docker Monitoring #4271) =="
if ! ensure_cadvisor; then
  warn "cAdvisor :8088 KO — dashboard Docker Monitoring vide"
  fail=1
fi

echo ""
log "== 2/7 Prometheus (host network + prometheus.yml 127.0.0.1) =="
if [[ -x "${SCRIPT_DIR}/repair-prometheus-host-targets.sh" ]]; then
  bash "${SCRIPT_DIR}/repair-prometheus-host-targets.sh" || {
    warn "repair-prometheus-host-targets partiel"
    ensure_prometheus_ready || fail=1
  }
else
  ensure_prometheus_ready || fail=1
fi

echo ""
log "== 3/7 Cibles dynamiques (EMQX, WS, API k8s) =="
[[ -x "${SCRIPT_DIR}/sync-emqx-prometheus-targets.sh" ]] \
  && "${SCRIPT_DIR}/sync-emqx-prometheus-targets.sh" || true
[[ -x "${K8S_SCRIPTS}/sync-prometheus-ws-targets.sh" ]] \
  && "${K8S_SCRIPTS}/sync-prometheus-ws-targets.sh" || true
[[ -x "${K8S_SCRIPTS}/sync-prometheus-api-targets.sh" ]] \
  && "${K8S_SCRIPTS}/sync-prometheus-api-targets.sh" || true
curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || docker restart wise-eat-prometheus >/dev/null 2>&1 || true
sleep 5

echo ""
log "== 4/7 Séries Prometheus (attente scrapes ~30s) =="
series_ok=0
for i in $(seq 1 15); do
  if prometheus_has_series; then
    series_ok=1
    up_count="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
      --data-urlencode 'query=count(up==1)' 2>/dev/null \
      | python3 -c "import json,sys; r=json.load(sys.stdin).get('data',{}).get('result',[]); print(r[0]['value'][1] if r else '0')" 2>/dev/null || echo '?')"
    log "OK Prometheus — count(up==1)=${up_count} (tentative ${i}/15)"
    break
  fi
  sleep 2
done
if [[ "${series_ok}" -eq 0 ]]; then
  warn "Prometheus ne remonte aucune cible UP — diagnostic /targets :"
  curl -sf http://127.0.0.1:9090/api/v1/targets 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d.get('data',{}).get('activeTargets',[]):
    h=t.get('health','?')
    if h!='up':
        lbl=t.get('labels',{})
        print(f\"  DOWN job={lbl.get('job','?')} url={t.get('scrapeUrl','?')} err={t.get('lastError','')[:80]}\")
" 2>/dev/null || true
  fail=1
fi

echo ""
log "== 5/7 Grafana → Prometheus (fix N/A global) =="
if ! ensure_grafana_prometheus_link; then
  warn "Lien Grafana/Prometheus KO"
  fail=1
fi

echo ""
log "== 6/7 Restart Grafana (recharge provisioning datasource) =="
docker restart wise-eat-grafana >/dev/null 2>&1 || true
sleep 5
if curl -sf http://127.0.0.1:3000/api/health >/dev/null; then
  log "OK Grafana http://127.0.0.1:3000"
else
  warn "Grafana ne répond pas sur :3000"
  fail=1
fi

echo ""
log "== 7/7 Vérification =="
bash "${SCRIPT_DIR}/verify-monitoring.sh" || fail=1

echo ""
if [[ "${fail}" -eq 0 ]]; then
  log "Stack OK — rafraîchir https://console.wise-eat.com (Ctrl+Shift+R)"
else
  warn "Réparation partielle — voir les WARN ci-dessus"
  exit 1
fi
