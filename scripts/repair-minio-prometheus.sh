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

if ! docker inspect wise-eat-minio --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
  | grep -q 'wise-eat-infra'; then
  log "Connexion wise-eat-minio → réseau wise-eat-infra"
  docker network connect wise-eat-infra wise-eat-minio 2>/dev/null || true
fi

# Recréer MinIO si le réseau wise-eat-infra a été ajouté après le premier démarrage.
if [[ -f "${MINIO_ENV}" ]]; then
  log "Recréation MinIO (réseaux Docker à jour)"
  cd "${MINIO_DIR}"
  docker compose --env-file .env.minio up -d --force-recreate minio
  sleep 3
fi

sync_component monitoring
cd "${MON_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

docker compose --env-file .env.monitoring up -d prometheus
sleep 3

if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée"
else
  docker compose --env-file .env.monitoring restart prometheus
  sleep 5
fi

log "Test scrape depuis Prometheus → wise-eat-minio:9000 (pas host:9000 = API Nest)"
if docker exec wise-eat-prometheus wget -qO- \
  'http://wise-eat-minio:9000/minio/v2/metrics/cluster' 2>/dev/null \
  | head -5 | grep -q minio_; then
  log "OK  Prometheus → wise-eat-minio:9000"
else
  warn "FAIL scrape wise-eat-minio:9000"
  warn "      docker network inspect wise-eat-infra"
  warn "      docker inspect wise-eat-minio --format '{{json .NetworkSettings.Networks}}'"
  docker exec wise-eat-prometheus wget -S -O- \
    'http://wise-eat-minio:9000/minio/health/live' 2>&1 | tail -8 || true
fi

sleep 5
log "Requête Prometheus up{job=\"minio\"}"
curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job="minio"}' \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('status')!='success':
    print('  ERREUR', d); raise SystemExit(1)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (vide — voir http://127.0.0.1:9090/targets job=minio)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
" || warn "up{job=minio} encore vide"

curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=minio_cluster_health_status{job="minio"}' \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
print(f'  minio_cluster_health_status: {len(r)} série(s)')
" || true

bash "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" 2>/dev/null || true
docker compose --env-file .env.monitoring up -d grafana 2>/dev/null || true

log "Terminé — ne pas scraper host:9000 (conflit API Nest NODE_PORT=9000)"
