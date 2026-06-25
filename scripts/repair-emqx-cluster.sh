#!/usr/bin/env bash
# Force le cluster EMQX 3 nœuds (primary + 2 réplicas) — corrige « 1 container » Docker Desktop.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation cluster EMQX (3 nœuds) ==="

sync_component emqx
cd "${EMQX_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.emqx ]]; then
  bash "${SCRIPT_DIR}/install-emqx.sh"
  exit 0
fi

ensure_emqx_cluster_env() {
  local seeds='[emqx@wise-eat-emqx-1,emqx@wise-eat-emqx-2,emqx@wise-eat-emqx-3]'
  if grep -q '^EMQX_CLUSTER_B_ENABLED=' .env.emqx; then
    sed -i 's|^EMQX_CLUSTER_B_ENABLED=.*|EMQX_CLUSTER_B_ENABLED=true|' .env.emqx
  else
    echo 'EMQX_CLUSTER_B_ENABLED=true' >> .env.emqx
  fi
  if grep -q '^EMQX_CLUSTER_STATIC_SEEDS=' .env.emqx; then
    sed -i "s|^EMQX_CLUSTER_STATIC_SEEDS=.*|EMQX_CLUSTER_STATIC_SEEDS=${seeds}|" .env.emqx
  else
    echo "EMQX_CLUSTER_STATIC_SEEDS=${seeds}" >> .env.emqx
  fi
}

ensure_emqx_cluster_env

set -a && source .env.emqx && set +a
export EMQX_CLUSTER_STATIC_SEEDS='[emqx@wise-eat-emqx-1,emqx@wise-eat-emqx-2,emqx@wise-eat-emqx-3]'

mkdir -p data-emqx-1 data-emqx-2 data-emqx-3
chown -R 1000:1000 data-emqx-1 data-emqx-2 data-emqx-3

log "Recréation cluster EMQX (wise-eat-emqx-1/2/3)…"
docker compose --env-file .env.emqx up -d --force-recreate --remove-orphans

sleep 12

for n in 1 2 3; do
  if wait_for_container_running "wise-eat-emqx-${n}" 120; then
    log "OK  wise-eat-emqx-${n}"
  else
    warn "FAIL wise-eat-emqx-${n} — docker logs wise-eat-emqx-${n}"
    docker logs --tail=30 "wise-eat-emqx-${n}" 2>&1 || true
  fi
done

ensure_emqx_on_wise_eat_infra || true

if docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null; then
  log "Cluster EMQX :"
  docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | sed 's/^/[wise-eat]      /'
else
  warn "Cluster pas encore formé — attendre 30s puis : docker exec wise-eat-emqx-1 emqx ctl cluster status"
fi

running="$(docker ps --format '{{.Names}}' | grep -c '^wise-eat-emqx-' || true)"
if [[ "${running}" -lt 3 ]]; then
  die "Seulement ${running}/3 nœuds EMQX — voir docker compose ps && docker logs"
fi

bash "${SCRIPT_DIR}/bootstrap-emqx-auth.sh" 2>/dev/null || true
bash "${SCRIPT_DIR}/repair-emqx-prometheus.sh" 2>/dev/null || true

log "Cluster EMQX OK — 3 conteneurs (primary :1883 + 2 réplicas cluster)"
