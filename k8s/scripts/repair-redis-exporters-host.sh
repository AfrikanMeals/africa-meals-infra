#!/usr/bin/env bash
# Recrée les redis_exporter en network_mode:host → 127.0.0.1:ports Redis k8s.
# Requis après cutover Redis Docker → k8s (DNS wise-eat-redis-* morts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

REDIS_ENV="${REDIS_ENV:-${INFRA_ROOT}/redis/.env.redis}"
MON_ENV="${INFRA_ROOT}/monitoring/.env.monitoring"
EXPORTER_IMAGE="${REDIS_EXPORTER_IMAGE:-oliver006/redis_exporter:v1.67.0}"

if [[ ! -f "${REDIS_ENV}" ]]; then
  die "Absent ${REDIS_ENV}"
fi
set -a
# shellcheck disable=SC1090
source "${REDIS_ENV}"
# Mots de passe exporters aussi dans .env.monitoring si présent
[[ -f "${MON_ENV}" ]] && source "${MON_ENV}" || true
set +a

: "${CACHE_REDIS_PASSWORD:?CACHE_REDIS_PASSWORD requis}"
: "${BULL_REDIS_PASSWORD:?BULL_REDIS_PASSWORD requis}"

docker rm -f \
  wise-eat-redis-exporter-cache \
  wise-eat-redis-exporter-bullmq \
  wise-eat-redis-exporter-cache-replica-1 \
  wise-eat-redis-exporter-cache-replica-2 \
  wise-eat-redis-exporter-bullmq-replica-1 \
  wise-eat-redis-exporter-bullmq-replica-2 \
  2>/dev/null || true

run_exporter() {
  local name="$1" addr="$2" listen="$3" user="$4" pass="$5"
  log "Recreate ${name} → ${addr} (listen ${listen})"
  docker run -d --name "${name}" --restart unless-stopped \
    --network host \
    -e REDIS_ADDR="${addr}" \
    -e REDIS_USER="${user}" \
    -e REDIS_PASSWORD="${pass}" \
    -e REDIS_EXPORTER_INCL_SYSTEM_METRICS=true \
    "${EXPORTER_IMAGE}" \
    --web.listen-address="${listen}"
}

# Jobs Prometheus inchangés : 9121–9126
run_exporter wise-eat-redis-exporter-cache \
  "redis://127.0.0.1:6379" "127.0.0.1:9121" wise-eat-cache "${CACHE_REDIS_PASSWORD}"
run_exporter wise-eat-redis-exporter-bullmq \
  "redis://127.0.0.1:6380" "127.0.0.1:9122" wise-eat-bull "${BULL_REDIS_PASSWORD}"
run_exporter wise-eat-redis-exporter-cache-replica-1 \
  "redis://127.0.0.1:6371" "127.0.0.1:9123" wise-eat-cache "${CACHE_REDIS_PASSWORD}"
run_exporter wise-eat-redis-exporter-bullmq-replica-1 \
  "redis://127.0.0.1:6390" "127.0.0.1:9124" wise-eat-bull "${BULL_REDIS_PASSWORD}"
run_exporter wise-eat-redis-exporter-cache-replica-2 \
  "redis://127.0.0.1:6372" "127.0.0.1:9125" wise-eat-cache "${CACHE_REDIS_PASSWORD}"
run_exporter wise-eat-redis-exporter-bullmq-replica-2 \
  "redis://127.0.0.1:6391" "127.0.0.1:9126" wise-eat-bull "${BULL_REDIS_PASSWORD}"

sleep 2
for port in 9121 9122 9123 9124 9125 9126; do
  up="$(curl -sf "http://127.0.0.1:${port}/metrics" 2>/dev/null | awk '/^redis_up /{print $2; exit}' || echo missing)"
  if [[ "${up}" == "1" ]]; then
    log "OK  exporter :${port} redis_up=1"
  else
    warn "FAIL exporter :${port} redis_up=${up}"
  fi
done

log "Exporters Redis host-network OK"
