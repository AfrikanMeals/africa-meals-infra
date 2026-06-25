#!/usr/bin/env bash
# Répare le scrape Prometheus → MinIO (Grafana vide malgré curl :9000 OK).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation scrape MinIO → Prometheus ==="

ensure_docker
ensure_wise_eat_infra_network

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-minio$'; then
  warn "MinIO absent — installation"
  bash "${SCRIPT_DIR}/install-minio.sh"
fi

sync_component minio
cd "${MINIO_DIR}"
set -a && source .env.minio && set +a

log "Recréation MinIO (réseaux wise-eat-minio + wise-eat-infra)"
docker compose --env-file .env.minio up -d --force-recreate minio

if ! wait_for_minio_local "${MINIO_API_PORT:-9000}"; then
  die "MinIO ne répond pas sur 127.0.0.1:${MINIO_API_PORT:-9000} — docker logs wise-eat-minio"
fi

ensure_minio_on_wise_eat_infra || die "wise-eat-minio injoignable sur wise-eat-infra"

log "Réseaux MinIO : $(docker inspect wise-eat-minio --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')"

sync_component monitoring
cd "${MON_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

docker compose --env-file .env.monitoring up -d prometheus

if ! wait_for_prometheus_ready 60; then
  warn "Prometheus pas ready — logs :"
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

log "Test réseau wise-eat-infra → wise-eat-minio:9000"
if probe_minio_from_infra_network; then
  log "OK  wise-eat-infra → wise-eat-minio:9000 (métriques cluster)"
else
  warn "FAIL curl depuis wise-eat-infra"
  docker network inspect wise-eat-infra --format '{{range .Containers}}{{.Name}} {{end}}' || true
  docker inspect wise-eat-minio --format '{{json .NetworkSettings.Networks}}' || true
  die "MinIO injoignable depuis wise-eat-infra — vérifier docker compose minio"
fi

log "Attente scrape Prometheus (20s)…"
sleep 20

log "Requête Prometheus up{job=\"minio\"}"
prom_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=up{job="minio"}' || true)"
if [[ -z "${prom_out}" ]]; then
  warn "Prometheus API vide — http://127.0.0.1:9090/targets"
else
  echo "${prom_out}" | python3 -c "
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print('  (réponse vide)'); raise SystemExit(1)
d=json.loads(raw)
if d.get('status')!='success':
    print('  ERREUR', d); raise SystemExit(1)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (vide — job minio DOWN dans /targets)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
"
fi

prom_health="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=minio_cluster_health_status{job="minio"}' || true)"
if [[ -n "${prom_health}" ]]; then
  echo "${prom_health}" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
print(f'  minio_cluster_health_status: {len(r)} série(s)')
"
fi

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" 2>/dev/null || true
docker compose --env-file .env.monitoring up -d grafana 2>/dev/null || true

log "Terminé — scrape via wise-eat-minio:9000 (pas host:9000 = API Nest)"
