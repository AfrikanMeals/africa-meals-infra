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
docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps loki promtail
# Recreate Grafana pour recharger provisioning datasources/dashboards Logs.
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --no-deps grafana 2>/dev/null \
  || docker compose "${COMPOSE_ARGS[@]}" up -d grafana

# Reload Prometheus (jobs loki/promtail).
if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  log "Prometheus config rechargée (jobs loki/promtail)"
else
  docker compose "${COMPOSE_ARGS[@]}" restart prometheus 2>/dev/null || true
fi

sleep 5
bash "${SCRIPT_DIR}/verify-loki-stack.sh" || warn "verify-loki-stack partiel"

log "Grafana → dossier Dashboards « Logs » · Explore → datasource Loki"
log "Ready : curl -sf http://127.0.0.1:3100/ready"
log "Promtail : curl -sf http://127.0.0.1:9080/ready"
