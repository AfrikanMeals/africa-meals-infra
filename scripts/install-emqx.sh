#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component emqx
cd "${EMQX_DIR}"
ensure_docker
ensure_wise_eat_infra_network

EMQX_CLUSTER_STATIC_SEEDS='[emqx@wise-eat-emqx-1,emqx@wise-eat-emqx-2,emqx@wise-eat-emqx-3]'

if [[ ! -f .env.emqx ]]; then
  log "Création .env.emqx (secrets aléatoires)"
  EMQX_ERLANG_COOKIE="$(openssl rand -hex 16)"
  EMQX_DASHBOARD_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  MQTT_BROKER_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  MQTT_ADMIN_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  cat > .env.emqx <<EOF
EMQX_CLUSTER_B_ENABLED=true
EMQX_ERLANG_COOKIE=${EMQX_ERLANG_COOKIE}
EMQX_DASHBOARD_USERNAME=admin
EMQX_DASHBOARD_PASSWORD=${EMQX_DASHBOARD_PASSWORD}
MQTT_BROKER_PASSWORD=${MQTT_BROKER_PASSWORD}
MQTT_ADMIN_PASSWORD=${MQTT_ADMIN_PASSWORD}
EMQX_MQTT_PORT=1883
EMQX_WS_PORT=8083
EMQX_DASHBOARD_PORT=18083
EMQX_BROKER_DOMAIN=${EMQX_BROKER_DOMAIN}
EMQX_MQTTS_PORT=8883
EMQX_WSS_PORT=8884
EMQX_CLUSTER_STATIC_SEEDS=${EMQX_CLUSTER_STATIC_SEEDS}
EOF
  chmod 600 .env.emqx
  log "Secrets enregistrés dans ${EMQX_DIR}/.env.emqx"
else
  # Migration : seeds JSON → format EMQX officiel + cluster forcé
  if grep -q '^EMQX_CLUSTER_B_ENABLED=' .env.emqx; then
    sed -i 's|^EMQX_CLUSTER_B_ENABLED=.*|EMQX_CLUSTER_B_ENABLED=true|' .env.emqx
  else
    echo 'EMQX_CLUSTER_B_ENABLED=true' >> .env.emqx
  fi
  if grep -q '^EMQX_CLUSTER_STATIC_SEEDS=' .env.emqx; then
    sed -i "s|^EMQX_CLUSTER_STATIC_SEEDS=.*|EMQX_CLUSTER_STATIC_SEEDS=${EMQX_CLUSTER_STATIC_SEEDS}|" .env.emqx
  else
    echo "EMQX_CLUSTER_STATIC_SEEDS=${EMQX_CLUSTER_STATIC_SEEDS}" >> .env.emqx
  fi
fi

set -a && source .env.emqx && set +a
export EMQX_CLUSTER_STATIC_SEEDS

log "EMQX : 1 primary + 2 réplicas (cluster static, 3 conteneurs)"
mkdir -p data-emqx-1 data-emqx-2 data-emqx-3
chown -R 1000:1000 data-emqx-1 data-emqx-2 data-emqx-3
log "OK data-emqx-1 data-emqx-2 data-emqx-3 → 1000:1000"

COMPOSE_ARGS=(--env-file .env.emqx)

prepare_emqx_compose_stack .env.emqx

log "Démarrage EMQX Docker (primary puis réplicas)"
docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps emqx-1
if ! wait_for_emqx_api "${EMQX_DASHBOARD_PORT:-18083}" 45 wise-eat-emqx-1; then
  warn "Primary EMQX lent — diagnostic"
  diagnose_emqx_container wise-eat-emqx-1
fi
docker compose "${COMPOSE_ARGS[@]}" up -d --remove-orphans
sleep 12
docker compose "${COMPOSE_ARGS[@]}" ps

if wait_for_container_running wise-eat-emqx-1 60; then
  log "OK  emqx-1 primary :${EMQX_MQTT_PORT:-1883}"
else
  warn "FAIL emqx-1 — docker logs wise-eat-emqx-1"
fi

for n in 2 3; do
  if wait_for_container_running "wise-eat-emqx-${n}" 120; then
    log "OK  emqx-${n} réplica (cluster)"
  else
    warn "FAIL emqx-${n} — docker logs wise-eat-emqx-${n}"
    docker logs --tail=25 "wise-eat-emqx-${n}" 2>&1 || true
  fi
done

running="$(docker ps --format '{{.Names}}' | grep -c '^wise-eat-emqx-' || true)"
if [[ "${running}" -lt 3 ]]; then
  warn "Seulement ${running}/3 nœuds — lancer : sudo ./install.sh repair-emqx-cluster"
fi

if docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | grep -qiE 'running|emqx@'; then
  log "Cluster EMQX actif"
  docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | sed 's/^/[wise-eat]      /' || true
else
  warn "Cluster EMQX — vérifier : docker exec wise-eat-emqx-1 emqx ctl cluster status"
fi

ensure_emqx_on_wise_eat_infra || true

bash "${SCRIPT_DIR}/bootstrap-emqx-auth.sh"

cat <<EOF

Cluster (3 conteneurs) :
  Primary   wise-eat-emqx-1  → 127.0.0.1:${EMQX_MQTT_PORT:-1883} (MQTT public local)
  Réplica 1 wise-eat-emqx-2  → cluster interne (wise-eat-infra)
  Réplica 2 wise-eat-emqx-3  → cluster interne (wise-eat-infra)

  Dashboard  http://127.0.0.1:${EMQX_DASHBOARD_PORT:-18083}  (admin / voir .env.emqx)

Remote TLS (après ./install.sh emqx-broker + certbot) :
  MQTTS      mqtts://${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}:${EMQX_MQTTS_PORT:-8883}
  WSS        wss://${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}:${EMQX_WSS_PORT:-8884}/mqtt

Utilisateurs MQTT :
  wise-eat-mqtt  → WS (subscriber)   MQTT_BROKER_PASSWORD
  wise-eat-admin → API (publisher)    MQTT_ADMIN_PASSWORD

EMQX installé dans ${EMQX_DIR}
EOF
