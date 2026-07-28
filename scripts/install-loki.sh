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

# k3s : Promtail lit /etc/rancher/k3s/k3s.yaml (pods). Absent = Docker + journal seulement.
if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
  warn "k3s.yaml absent — scrape pods k8s désactivé jusqu’à install k3s"
fi

log "Pull + up Loki / Promtail (+ Grafana datasource)"
COMPOSE_ARGS=(--env-file .env.monitoring)
docker compose "${COMPOSE_ARGS[@]}" pull loki promtail
# --no-deps : ne pas recréer redis-exporter / dépendances (conflits de noms).
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --no-deps loki promtail

# Grafana : restart seul (recharge provisioning loki.yml + dashboards Logs).
if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-grafana'; then
  docker restart wise-eat-grafana
  log "Grafana redémarré (datasource Loki + folder Logs)"
else
  docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps grafana || warn "Grafana absent — sudo ./install.sh monitoring"
fi

# Reload Prometheus (jobs loki/promtail) — non bloquant.
curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true

sleep 8

# Sanity : Grafana (host) doit joindre Loki — sinon Explore « Unable to connect ».
if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-grafana'; then
  gnet="$(docker inspect wise-eat-grafana -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${gnet}" != "host" ]]; then
    warn "Grafana network_mode=${gnet} (attendu host) — sudo ./install.sh repair-grafana-stack"
  elif docker exec wise-eat-grafana wget -qO- --timeout=5 http://127.0.0.1:3100/ready 2>/dev/null \
    | grep -qiE 'ready'; then
    log "OK  Grafana → Loki (127.0.0.1:3100)"
  else
    warn "FAIL Grafana → Loki — curl/wget depuis le conteneur Grafana"
    docker exec wise-eat-grafana wget -S -O- --timeout=5 http://127.0.0.1:3100/ready 2>&1 | tail -15 || true
  fi
fi

bash "${SCRIPT_DIR}/verify-loki-stack.sh" || warn "verify-loki-stack partiel"

# Smoke query (doit renvoyer des lignes si streams OK).
if curl -sfG --data-urlencode 'query={job=~".+"}' \
  --data-urlencode 'limit=5' \
  "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "start=$(date -u -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" 2>/dev/null \
  | grep -q '"values"'; then
  log "OK  Loki query_range a des valeurs (1h)"
else
  warn "query_range vide — attendre 30s ou voir Explore Grafana"
fi

log "Grafana → Connections → Data sources → Loki doit être http://127.0.0.1:3100"
log "Explore → Loki → {job=\"kubernetes\"} ou {job=\"docker\"}"
log "Dashboard → folder Logs (Search défaut = .*)"
