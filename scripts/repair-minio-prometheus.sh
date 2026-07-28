#!/usr/bin/env bash
# Répare le scrape Prometheus → MinIO (Grafana vide malgré curl :9000 OK).
# Post-migration K8s : scrape 127.0.0.1:9000 (hostPort) — pas wise-eat-minio Docker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation scrape MinIO → Prometheus ==="

ensure_docker
API_PORT="${MINIO_API_PORT:-9000}"

# Détecter MinIO K8s (hostPort) vs Docker — ne pas recreate Docker si pods actifs.
minio_k8s_ready=false
if command -v kubectl >/dev/null 2>&1 || command -v k3s >/dev/null 2>&1; then
  KUBECTL=(kubectl)
  if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    KUBECTL=(sudo k3s kubectl)
  fi
  if "${KUBECTL[@]}" -n wise-eat get deploy/minio >/dev/null 2>&1; then
    ready="$("${KUBECTL[@]}" -n wise-eat get deploy/minio -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    if [[ "${ready}" == "1" ]]; then
      minio_k8s_ready=true
      log "MinIO K8s détecté (deploy/minio Ready)"
    fi
  fi
fi

if [[ "${minio_k8s_ready}" != "true" ]]; then
  ensure_wise_eat_infra_network
  if ! docker ps --format '{{.Names}}' | grep -q '^wise-eat-minio$'; then
    warn "MinIO Docker absent et pas de pod Ready — install Docker legacy"
    bash "${SCRIPT_DIR}/install-minio.sh"
  fi
  sync_component minio
  cd "${MINIO_DIR}"
  set -a && source .env.minio && set +a
  API_PORT="${MINIO_API_PORT:-9000}"
  log "Recréation MinIO Docker (réseaux wise-eat-minio + wise-eat-infra)"
  docker compose --env-file .env.minio up -d --force-recreate minio
  ensure_minio_on_wise_eat_infra || true
else
  if [[ -f "${MINIO_ENV}" ]]; then
    set -a && source "${MINIO_ENV}" && set +a
    API_PORT="${MINIO_API_PORT:-9000}"
  fi
fi

if ! wait_for_minio_local "${API_PORT}"; then
  die "MinIO ne répond pas sur 127.0.0.1:${API_PORT}"
fi

log "Attente métriques MinIO (endpoint /minio/v2/metrics/cluster)…"
for _ in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:${API_PORT}/minio/v2/metrics/cluster" \
    | grep -qE '(^|\n)minio_cluster_health_status'; then
    break
  fi
  sleep 1
done

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

# Prometheus en network_mode=host scrape 127.0.0.1:9000 (prometheus.yml).
log "Test métriques locales 127.0.0.1:${API_PORT}"
if curl -sf "http://127.0.0.1:${API_PORT}/minio/v2/metrics/cluster" \
  | grep -qE '(^|\n)minio_'; then
  log "OK  métriques MinIO sur 127.0.0.1:${API_PORT}"
else
  die "Métriques MinIO absentes sur 127.0.0.1:${API_PORT}"
fi

log "Attente scrape Prometheus (20s)…"
sleep 20

log "Requête Prometheus up{job=~\"minio-cluster|minio-node\"}"
prom_out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job=~"minio-cluster|minio-node|minio"}' || true)"
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
  --data-urlencode 'query=minio_cluster_health_status{job=~"minio-cluster|minio-node|minio"}' || true)"
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

# Dashboard MinIO provisionné en lecture seule — restart Grafana pour recharger JSON patché.
if docker ps --format '{{.Names}}' | grep -q '^wise-eat-grafana$'; then
  log "Restart Grafana (recharge dashboard MinIO provisionné)"
  docker compose --env-file .env.monitoring restart grafana 2>/dev/null || true
fi

bash "${SCRIPT_DIR}/verify-minio-ops.sh" || warn "verify-minio-ops : corriger avant de valider Grafana"

# Forcer rechargement du dashboard provisionné (sites primary/replicas).
if docker ps --format '{{.Names}}' | grep -q '^wise-eat-grafana$'; then
  docker compose --env-file .env.monitoring up -d grafana 2>/dev/null || true
fi

log "Terminé — scrape primary:9000 + replica-1:9002 + replica-2:9004 (cluster/node/bucket)"
log "Grafana : filtre « MinIO site » = primary | replica-1 | replica-2"
log "Admin console : https://cdn.wise-eat.com"
