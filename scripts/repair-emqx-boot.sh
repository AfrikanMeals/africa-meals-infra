#!/usr/bin/env bash
# Recovery EMQX crash-loop (prometheus schema : collectors vs legacy enable).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Recovery EMQX (crash-loop / 502 worker) ==="

ensure_docker
ensure_wise_eat_infra_network
sync_component emqx

[[ -f "${EMQX_DIR}/.env.emqx" ]] || die ".env.emqx absent — sudo ./install.sh emqx"

cd "${EMQX_DIR}"
set -a && source .env.emqx && set +a

log "Arrêt conteneurs EMQX (sortie crash-loop)"
docker compose --env-file .env.emqx stop emqx-1 emqx-2 emqx-3 2>/dev/null || true

fix_emqx_cluster_hocon_prometheus

log "Recréation EMQX (docker-compose corrigé)"
docker compose --env-file .env.emqx up -d --force-recreate

ensure_emqx_on_wise_eat_infra || true

if ! wait_for_emqx_api "${EMQX_DASHBOARD_PORT:-18083}" 90; then
  diagnose_emqx_container wise-eat-emqx-1
  die "EMQX toujours injoignable — voir docker logs wise-eat-emqx-1"
fi

if curl -sf "http://127.0.0.1:${EMQX_DASHBOARD_PORT:-18083}/api/v5/prometheus/stats" \
  | grep -q 'emqx_connections_count'; then
  log "OK  /api/v5/prometheus/stats"
else
  warn "Métriques Prometheus absentes — sudo ./install.sh repair-emqx-prometheus"
fi

if command -v nginx >/dev/null 2>&1; then
  log "Reload nginx (worker.wise-eat.com)"
  nginx_test_and_reload || warn "nginx reload échoué"
fi

log "Terminé — tester : curl -sf http://127.0.0.1:${EMQX_DASHBOARD_PORT:-18083}/api/v5/status"
