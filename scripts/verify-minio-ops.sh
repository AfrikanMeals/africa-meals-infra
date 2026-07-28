#!/usr/bin/env bash
# Vérifie MinIO Admin (console) + scrape Grafana/Prometheus après Docker ou K8s.
# Usage : sudo ./verify-minio-ops.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

API_PORT="${MINIO_API_PORT:-9000}"
CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
FAILS=0

ok() { log "OK  $*"; }
bad() { warn "FAIL $*"; FAILS=$((FAILS + 1)); }

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
  API_PORT="${MINIO_API_PORT:-9000}"
  CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
  STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
  CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
fi

log "=== Vérif MinIO ops (API + Admin console + Grafana/Prometheus) ==="

# 1. API S3 locale (hostPort K8s ou bind Docker)
if curl -sf "http://127.0.0.1:${API_PORT}/minio/health/live" >/dev/null; then
  ok "API locale :${API_PORT}/minio/health/live"
else
  bad "API locale :${API_PORT} — pods/Docker MinIO ?"
fi

# 2. Console Admin locale (nginx → 127.0.0.1:9001)
# La console répond souvent 200/403 sur / — accepter toute réponse HTTP.
console_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CONSOLE_PORT}/" || echo 000)"
if [[ "${console_code}" =~ ^(200|204|301|302|307|401|403)$ ]]; then
  ok "Console locale :${CONSOLE_PORT} (HTTP ${console_code})"
else
  bad "Console locale :${CONSOLE_PORT} (HTTP ${console_code}) — hostPort 9001 / MINIO console"
fi

# 3. Public S3 + Console (nginx)
if curl -sfI "https://${STORAGE_DOMAIN}/minio/health/live" >/dev/null 2>&1 \
  || curl -sf "https://${STORAGE_DOMAIN}/minio/health/live" >/dev/null 2>&1; then
  ok "Public S3 https://${STORAGE_DOMAIN}"
else
  bad "Public S3 https://${STORAGE_DOMAIN}"
fi

cdn_code="$(curl -s -o /dev/null -w '%{http_code}' "https://${CONSOLE_DOMAIN}/" || echo 000)"
# 401 = basic auth nginx OK (console joignable) ; 200 si déjà authentifié.
if [[ "${cdn_code}" =~ ^(200|301|302|401|403)$ ]]; then
  ok "MinIO Admin https://${CONSOLE_DOMAIN} (HTTP ${cdn_code})"
else
  bad "MinIO Admin https://${CONSOLE_DOMAIN} (HTTP ${cdn_code})"
fi

# 4. Métriques Prometheus (requis Grafana dashboard MinIO)
if curl -sf "http://127.0.0.1:${API_PORT}/minio/v2/metrics/cluster" \
  | grep -qE '(^|\n)minio_cluster_health_status'; then
  ok "Métriques cluster /minio/v2/metrics/cluster"
else
  bad "Métriques cluster absentes — Grafana MinIO sera vide"
fi

# 5. Scrape Prometheus — primary + 2 réplicas (job minio-cluster)
if curl -sf http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
  sites_ok=0
  for site in primary replica-1 replica-2; do
    prom_up="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
      --data-urlencode "query=up{job=\"minio-cluster\",minio_site=\"${site}\"}" \
      2>/dev/null || true)"
    if echo "${prom_up}" | grep -q '"value":\[.*,"1"\]'; then
      ok "Prometheus scrape minio-cluster minio_site=${site}=1"
      sites_ok=$((sites_ok + 1))
    else
      bad "Prometheus scrape minio_site=${site} DOWN — reload prometheus.yml (3 targets)"
    fi
  done
  # Métriques bucket (fallback Number of Buckets / Objects)
  bucket_up="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=up{job="minio-bucket",minio_site="primary"}' 2>/dev/null || true)"
  if echo "${bucket_up}" | grep -q '"value":\[.*,"1"\]'; then
    ok "Prometheus scrape minio-bucket (primary)=1"
  else
    bad "Prometheus job minio-bucket DOWN — buckets/objets Grafana peuvent rester N/A"
  fi
  [[ "${sites_ok}" -ge 1 ]] || bad "Aucun site MinIO scrapé"
else
  bad "Prometheus injoignable :9090 — sudo ./install.sh monitoring"
fi

# 6. Grafana HTTP local (network_mode=host)
grafana_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000/api/health" || echo 000)"
if [[ "${grafana_code}" == "200" ]]; then
  ok "Grafana local :3000/api/health"
else
  # Console publique Grafana (si exposée)
  gpub="$(curl -s -o /dev/null -w '%{http_code}' "https://console.wise-eat.com/api/health" || echo 000)"
  if [[ "${gpub}" == "200" ]]; then
    ok "Grafana https://console.wise-eat.com/api/health"
  else
    bad "Grafana health (local :3000 → ${grafana_code}, public → ${gpub})"
  fi
fi

echo
if [[ "${FAILS}" -gt 0 ]]; then
  die "${FAILS} vérif(s) en échec — console Admin / Grafana MinIO non OK"
fi
log "Toutes les vérifs MinIO ops OK (Admin + Grafana/Prometheus)"
