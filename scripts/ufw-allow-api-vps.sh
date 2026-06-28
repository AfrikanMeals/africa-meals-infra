#!/usr/bin/env bash
# Autorise un VPS API distant (ex. CWP api.wise-eat.cloud) → Stunnel/MQTT publics.
#
# Usage (sur le serveur Wise Eat principal) :
#   sudo API_VPS_IP=193.203.169.34 ./scripts/ufw-allow-api-vps.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

API_VPS_IP="${API_VPS_IP:?API_VPS_IP requis (ex. 193.203.169.34)}"
MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"

command -v ufw >/dev/null 2>&1 || die "ufw absent"

log "UFW — autoriser ${API_VPS_IP} → Stunnel/MQTT/Memcached"

ufw allow from "${API_VPS_IP}" to any port "${MONGO_TLS_PORT}" proto tcp comment 'API VPS Mongo Stunnel'
for port in 6381 6382 6383 6384 6385 6386; do
  ufw allow from "${API_VPS_IP}" to any port "${port}" proto tcp comment "API VPS Redis :${port}"
done
ufw allow from "${API_VPS_IP}" to any port "${MEMCACHED_TLS_PORT:-11212}" proto tcp comment 'API VPS Memcached TLS'
ufw allow from "${API_VPS_IP}" to any port "${EMQX_MQTTS_PORT:-8883}" proto tcp comment 'API VPS MQTTS'
ufw allow from "${API_VPS_IP}" to any port "${EMQX_WSS_PORT:-8884}" proto tcp comment 'API VPS WSS'
ufw reload

log "OK — UFW mis à jour pour ${API_VPS_IP}"
log "IMPORTANT : ouvrir aussi ces ports dans le pare-feu PANEL hébergeur (Hetzner/OVH/CWP…)"
log "Test depuis le VPS API : nc -zv ${MONGO_TLS_DOMAIN:-db.wise-eat.com} ${MONGO_TLS_PORT}"
