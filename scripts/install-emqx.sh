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
EMQX_CLUSTER_STATIC_SEEDS='["emqx@wise-eat-emqx-1","emqx@wise-eat-emqx-2","emqx@wise-eat-emqx-3"]'
EOF
  chmod 600 .env.emqx
  log "Secrets enregistrés dans ${EMQX_DIR}/.env.emqx"
fi

set -a && source .env.emqx && set +a

if emqx_cluster_b_enabled; then
  EMQX_CLUSTER_STATIC_SEEDS='["emqx@wise-eat-emqx-1","emqx@wise-eat-emqx-2","emqx@wise-eat-emqx-3"]'
  log "EMQX : 1 primary + 2 réplicas (cluster static)"
  mkdir -p data-emqx-1 data-emqx-2 data-emqx-3
  COMPOSE_ARGS=(--env-file .env.emqx --profile cluster-b)
else
  EMQX_CLUSTER_STATIC_SEEDS='["emqx@wise-eat-emqx-1"]'
  log "EMQX : nœud unique (EMQX_CLUSTER_B_ENABLED=false)"
  mkdir -p data-emqx-1
  COMPOSE_ARGS=(--env-file .env.emqx)
  for old in wise-eat-emqx-2 wise-eat-emqx-3; do
    docker rm -f "${old}" 2>/dev/null || true
  done
fi

export EMQX_CLUSTER_STATIC_SEEDS

log "Démarrage EMQX Docker"
docker compose "${COMPOSE_ARGS[@]}" up -d
sleep 8
docker compose "${COMPOSE_ARGS[@]}" ps

if wait_for_container_running wise-eat-emqx-1 60; then
  log "OK  emqx-1 primary :${EMQX_MQTT_PORT:-1883}"
else
  warn "FAIL emqx-1 — docker logs wise-eat-emqx-1"
fi

if emqx_cluster_b_enabled; then
  for n in 2 3; do
    if wait_for_container_running "wise-eat-emqx-${n}" 90; then
      log "OK  emqx-${n} réplica (cluster)"
    else
      warn "FAIL emqx-${n} — docker logs wise-eat-emqx-${n}"
    fi
  done
  if docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | grep -q 'running'; then
    log "Cluster EMQX actif"
    docker exec wise-eat-emqx-1 /opt/emqx/bin/emqx ctl cluster status 2>/dev/null | sed 's/^/[wise-eat]      /' || true
  else
    warn "Cluster EMQX — vérifier : docker exec wise-eat-emqx-1 emqx ctl cluster status"
  fi
fi

bash "${SCRIPT_DIR}/bootstrap-emqx-auth.sh"

cat <<EOF

Primary (apps VPS en local) :
  MQTT       mqtt://127.0.0.1:${EMQX_MQTT_PORT:-1883}
  WebSocket  ws://127.0.0.1:${EMQX_WS_PORT:-8083}/mqtt
  Dashboard  http://127.0.0.1:${EMQX_DASHBOARD_PORT:-18083}  (admin / voir .env.emqx)

Remote TLS (après ./install.sh emqx-broker + certbot) :
  MQTTS      mqtts://${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}:${EMQX_MQTTS_PORT:-8883}
  WSS        wss://${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}:${EMQX_WSS_PORT:-8884}/mqtt

Utilisateurs MQTT :
  wise-eat-mqtt  → WS (subscriber)   MQTT_BROKER_PASSWORD
  wise-eat-admin → API (publisher)    MQTT_ADMIN_PASSWORD

EMQX installé dans ${EMQX_DIR}
EOF
