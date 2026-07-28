#!/usr/bin/env bash
# Déploie / met à jour Loki + Promtail (logs → Grafana dossier Logs).
# Usage : sudo ./install.sh loki   ou   sudo ./scripts/install-loki.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component monitoring
cd "${MON_DIR}"
ensure_docker

if [[ ! -f .env.monitoring ]]; then
  cp .env.example .env.monitoring
  chmod 600 .env.monitoring
fi
sanitize_monitoring_env_file .env.monitoring
source_dotenv .env.monitoring

# Défauts RAM Loki/Promtail (VPS 8 Go).
if ! grep -q '^LOKI_MEM_LIMIT=' .env.monitoring 2>/dev/null; then
  echo 'LOKI_MEM_LIMIT=384m' >> .env.monitoring
  echo 'LOKI_MEMSWAP_LIMIT=512m' >> .env.monitoring
fi
if ! grep -q '^PROMTAIL_MEM_LIMIT=' .env.monitoring 2>/dev/null; then
  echo 'PROMTAIL_MEM_LIMIT=192m' >> .env.monitoring
  echo 'PROMTAIL_MEMSWAP_LIMIT=256m' >> .env.monitoring
fi
source_dotenv .env.monitoring

[[ -f loki/loki-config.yml ]] || die "Absent loki/loki-config.yml — git pull"
[[ -f promtail/promtail-config.yml ]] || die "Absent promtail/promtail-config.yml — git pull"

if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
  warn "k3s.yaml absent — scrape pods k8s désactivé jusqu’à install k3s"
fi

COMPOSE_ARGS=(--env-file .env.monitoring)

log "Pull images Loki / Promtail"
docker compose "${COMPOSE_ARGS[@]}" pull loki promtail

# 1. Stop Promtail d’abord — sinon flood immédiat → Loki /ready = 503 → Grafana « Unable to connect ».
log "Stop Promtail (éviter flood pendant démarrage Loki)"
docker compose "${COMPOSE_ARGS[@]}" stop promtail 2>/dev/null || docker stop wise-eat-promtail 2>/dev/null || true

# 2. Loki seul jusqu’à /ready=200
log "Recreate Loki — attendre /ready"
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --no-deps loki
ready=0
for i in $(seq 1 45); do
  code="$(curl -s -o /tmp/loki-ready.body -w '%{http_code}' --max-time 2 http://127.0.0.1:3100/ready 2>/dev/null || echo 000)"
  body="$(cat /tmp/loki-ready.body 2>/dev/null || true)"
  if [[ "${code}" == "200" ]] && echo "${body}" | grep -qi ready; then
    log "OK  Loki /ready HTTP 200 (${i}s)"
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" != "1" ]]; then
  warn "Loki /ready pas encore 200 — logs :"
  docker logs wise-eat-loki --tail=30 2>&1 | sed 's/^/      /' || true
  warn "On démarre Promtail quand même ; Save & test Grafana peut échouer jusqu’à ready"
fi

# 3. Promtail après Loki ready
log "Start Promtail (drop Ollama + older_than 168h)"
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --no-deps promtail

# 4. Grafana restart (provisioning) — sans toucher aux exporters
if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-grafana'; then
  docker restart wise-eat-grafana
  log "Grafana redémarré (datasource Loki + folder Logs)"
else
  docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps grafana || warn "Grafana absent — sudo ./install.sh monitoring"
fi

curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true
sleep 5

# Health Grafana → Loki : /ready doit être 200 (sinon Save & test UI échoue).
if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-grafana'; then
  gnet="$(docker inspect wise-eat-grafana -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${gnet}" != "host" ]]; then
    warn "Grafana network_mode=${gnet} (attendu host)"
  else
    code="$(docker exec wise-eat-grafana wget -q -S -O- --timeout=5 http://127.0.0.1:3100/ready 2>&1 \
      | awk '/HTTP\//{print $2; exit}' || true)"
    if [[ "${code}" == "200" ]]; then
      log "OK  Grafana → Loki /ready HTTP 200"
    else
      warn "Grafana → Loki /ready HTTP ${code:-?} — attendre 30s puis Save & test à nouveau"
    fi
  fi
fi

bash "${SCRIPT_DIR}/verify-loki-stack.sh" || warn "verify-loki-stack partiel"

if curl -sfG --data-urlencode 'query={job=~".+"}' \
  --data-urlencode 'limit=5' \
  "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "start=$(date -u -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" 2>/dev/null \
  | grep -q '"values"'; then
  log "OK  Loki query_range a des valeurs (1h)"
else
  warn "query_range vide — attendre 30s"
fi

log "Datasource URL : http://127.0.0.1:3100 — Save & test seulement si curl -sf http://127.0.0.1:3100/ready → ready"
log "Explore → {job=\"kubernetes\"}  |  Dashboard Logs (Search=.*)"
