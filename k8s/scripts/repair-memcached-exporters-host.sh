#!/usr/bin/env bash
# Recrée les memcached-exporter en network_mode:host → scrape 127.0.0.1:11211/13/14.
# Requis après cutover Memcached Docker → k8s (DNS wise-eat-memcached* morts).
#
# Usage :
#   sudo ./repair-memcached-exporters-host.sh
#   sudo ./install.sh repair-memcached-exporters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

MEMCACHED_ENV="${MEMCACHED_ENV:-${INFRA_ROOT}/memcached/.env.memcached}"
PRIMARY_PORT=11211
R1_PORT=11213
R2_PORT=11214
if [[ -f "${MEMCACHED_ENV}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${MEMCACHED_ENV}"
  set +a
  PRIMARY_PORT="${MEMCACHED_PORT:-11211}"
  R1_PORT="${MEMCACHED_REPLICA_1_PORT:-11213}"
  R2_PORT="${MEMCACHED_REPLICA_2_PORT:-11214}"
fi

EXPORTER_IMAGE="${MEMCACHED_EXPORTER_IMAGE:-prom/memcached-exporter:v0.15.3}"

# 1. Arrêter les anciens exporters (réseau Docker → noms morts).
docker rm -f \
  wise-eat-memcached-exporter \
  wise-eat-memcached-exporter-replica-1 \
  wise-eat-memcached-exporter-replica-2 \
  2>/dev/null || true

# 2. Primary exporter — host network, metrics :9150
log "Recreate memcached-exporter → 127.0.0.1:${PRIMARY_PORT} (listen :9150)"
docker run -d --name wise-eat-memcached-exporter --restart unless-stopped \
  --network host \
  "${EXPORTER_IMAGE}" \
  --memcached.address="127.0.0.1:${PRIMARY_PORT}" \
  --web.listen-address="127.0.0.1:9150"

# 3. Replica exporters
log "Recreate memcached-exporter-replica-1 → 127.0.0.1:${R1_PORT} (listen :9151)"
docker run -d --name wise-eat-memcached-exporter-replica-1 --restart unless-stopped \
  --network host \
  "${EXPORTER_IMAGE}" \
  --memcached.address="127.0.0.1:${R1_PORT}" \
  --web.listen-address="127.0.0.1:9151"

log "Recreate memcached-exporter-replica-2 → 127.0.0.1:${R2_PORT} (listen :9152)"
docker run -d --name wise-eat-memcached-exporter-replica-2 --restart unless-stopped \
  --network host \
  "${EXPORTER_IMAGE}" \
  --memcached.address="127.0.0.1:${R2_PORT}" \
  --web.listen-address="127.0.0.1:9152"

sleep 2

# 4. Vérifier memcached_up
for port in 9150 9151 9152; do
  up="$(curl -sf "http://127.0.0.1:${port}/metrics" 2>/dev/null | awk '/^memcached_up /{print $2; exit}' || echo missing)"
  if [[ "${up}" == "1" ]]; then
    log "OK  exporter :${port} memcached_up=1"
  else
    warn "FAIL exporter :${port} memcached_up=${up}"
  fi
done

log "Exporters Memcached host-network OK (Prometheus scrape 127.0.0.1:9150/51/52 inchangé)"
