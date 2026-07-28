#!/usr/bin/env bash
# Recrée neo4j-exporter → Bolt sur hostPort k8s (127.0.0.1 / host-gateway :7687).
# Requis après cutover Neo4j Docker → k8s (DNS wise-eat-neo4j mort).
# Metrics restent sur 127.0.0.1:9217 (job Prometheus inchangé).
#
# Usage :
#   sudo ./repair-neo4j-exporter-host.sh
#   sudo ./install.sh repair-neo4j-exporters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

NEO4J_ENV="${NEO4J_ENV:-${INFRA_ROOT}/neo4j/.env.neo4j}"
MON_ENV="${INFRA_ROOT}/monitoring/.env.monitoring"
EXPORTER_IMAGE="${NEO4J_EXPORTER_IMAGE:-ghcr.io/papadanielvi/neo4j-exporter:latest}"

if [[ ! -f "${NEO4J_ENV}" ]]; then
  die "Absent ${NEO4J_ENV}"
fi
set -a
# shellcheck disable=SC1090
source "${NEO4J_ENV}"
[[ -f "${MON_ENV}" ]] && source "${MON_ENV}" || true
set +a

: "${NEO4J_PASSWORD:?NEO4J_PASSWORD requis}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"

docker rm -f wise-eat-neo4j-exporter 2>/dev/null || true

# Bridge + host-gateway : joindre hostPort 7687 ; publish metrics :9217 (comme compose).
log "Recreate neo4j-exporter → bolt://host.docker.internal:${BOLT_PORT} (listen :9217)"
docker run -d --name wise-eat-neo4j-exporter --restart unless-stopped \
  --add-host=host.docker.internal:host-gateway \
  -e NEO4J_URI="bolt://host.docker.internal:${BOLT_PORT}" \
  -e NEO4J_USER="${NEO4J_USER}" \
  -e NEO4J_PASSWORD="${NEO4J_PASSWORD}" \
  -p "127.0.0.1:9217:9121" \
  "${EXPORTER_IMAGE}"

sleep 3
up="$(curl -sf "http://127.0.0.1:9217/metrics" 2>/dev/null | awk '/^neo4j_exporter_up /{print $2; exit}' || echo missing)"
if [[ "${up}" == "1" ]]; then
  log "OK  exporter :9217 neo4j_exporter_up=1"
else
  warn "FAIL neo4j_exporter_up=${up} — docker logs wise-eat-neo4j-exporter"
  docker logs wise-eat-neo4j-exporter --tail=25 2>&1 || true
fi

# Sync creds monitoring pour futurs compose up
if [[ -f "${MON_ENV}" ]]; then
  for key in NEO4J_USER NEO4J_PASSWORD; do
    if grep -q "^${key}=" "${MON_ENV}" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${!key}|" "${MON_ENV}"
    else
      echo "${key}=${!key}" >> "${MON_ENV}"
    fi
  done
fi

log "Exporter Neo4j OK — job Prometheus :9217 inchangé"
