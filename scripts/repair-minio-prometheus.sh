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

sync_component monitoring
cd "${MON_DIR}"

if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-prometheus$'; then
  bash "${SCRIPT_DIR}/install-monitoring.sh"
fi

log "Recréation Prometheus (host.docker.internal:host-gateway pour scrape :9000)"
docker compose --env-file .env.monitoring up -d --force-recreate prometheus
sleep 5

if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée"
else
  warn "Reload HTTP échoué — conteneur redémarré via compose"
fi

log "Test scrape depuis le conteneur Prometheus"
if docker exec wise-eat-prometheus wget -qO- \
  'http://host.docker.internal:9000/minio/v2/metrics/cluster' 2>/dev/null \
  | head -3 | grep -q minio_; then
  log "OK  Prometheus → host.docker.internal:9000 (métriques cluster)"
else
  warn "FAIL scrape interne — vérifier MinIO sur 127.0.0.1:9000"
  docker exec wise-eat-prometheus wget -S -O- \
    'http://host.docker.internal:9000/minio/health/live' 2>&1 | tail -5 || true
fi

sleep 3
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
    print('  (vide — attendre 15s et réessayer, ou Targets dans Prometheus UI)')
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

log "Terminé — Grafana : MinIO / Wise Eat — MinIO Storage (variable scrape_jobs=minio)"
