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
  if grep -q '^EMQX_CLUSTER_B_ENABLED=' .env.emqx; then
    sed -i 's|^EMQX_CLUSTER_B_ENABLED=.*|EMQX_CLUSTER_B_ENABLED=true|' .env.emqx
  else
    echo 'EMQX_CLUSTER_B_ENABLED=true' >> .env.emqx
  fi
}

ensure_emqx_cluster_env

set -a && source .env.emqx && set +a

check_emqx_host_ports_free

prepare_emqx_compose_stack .env.emqx
log "Reset data cluster (primary + réplicas) — backup data-emqx-1 si non vide"
reset_emqx_primary_data_dir
reset_emqx_replica_data_dirs

COMPOSE=(docker compose --env-file .env.emqx)

start_emqx_primary() {
  log "Démarrage primary EMQX (wise-eat-emqx-1)…"
  "${COMPOSE[@]}" up -d --force-recreate --no-deps emqx-1
}

log "Étape 1/2 — primary EMQX (data fraîche)"
start_emqx_primary

if wait_for_emqx_api "${EMQX_DASHBOARD_PORT:-18083}" 45 wise-eat-emqx-1; then
  log "OK  primary EMQX API :${EMQX_DASHBOARD_PORT:-18083}"
else
  warn "Primary EMQX injoignable — second essai après diagnostic"
  diagnose_emqx_container wise-eat-emqx-1
  prepare_emqx_compose_stack .env.emqx
  reset_emqx_primary_data_dir
  start_emqx_primary
  if ! wait_for_emqx_api "${EMQX_DASHBOARD_PORT:-18083}" 45 wise-eat-emqx-1; then
    diagnose_emqx_container wise-eat-emqx-1
    die "Primary EMQX ne démarre pas — ports 1883/8083/18083 libres ? voir ss -ltnp"
  fi
  log "OK  primary EMQX après second essai"
fi

log "Étape 2/2 — réplicas EMQX (wise-eat-emqx-2/3)"
"${COMPOSE[@]}" up -d --force-recreate emqx-2 emqx-3

log "Attente réplicas (max 90s)…"
for n in 2 3; do
  if wait_for_container_running "wise-eat-emqx-${n}" 45; then
    log "OK  wise-eat-emqx-${n} running"
  else
    warn "FAIL wise-eat-emqx-${n}"
    diagnose_emqx_container "wise-eat-emqx-${n}"
  fi
done

ensure_emqx_on_wise_eat_infra || true

if docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null; then
  log "Cluster EMQX :"
  docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | sed 's/^/[wise-eat]      /'
else
  warn "Cluster en formation — réessayer : docker exec wise-eat-emqx-1 emqx ctl cluster status"
fi

running="$(docker ps --format '{{.Names}}' | grep -c '^wise-eat-emqx-' || true)"
if [[ "${running}" -lt 3 ]]; then
  "${COMPOSE[@]}" ps || true
  die "Seulement ${running}/3 nœuds EMQX actifs"
fi

bash "${SCRIPT_DIR}/bootstrap-emqx-auth.sh" 2>/dev/null || true
bash "${SCRIPT_DIR}/repair-emqx-prometheus.sh" 2>/dev/null || true

log "Cluster EMQX OK — 3 conteneurs (primary :1883 + 2 réplicas cluster)"
