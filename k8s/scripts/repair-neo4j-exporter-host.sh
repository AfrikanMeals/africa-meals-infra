#!/usr/bin/env bash
# Recrée neo4j-exporter → Bolt sur hostPort k8s (127.0.0.1:7687) en host network.
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
# Fix: host.docker.internal → bridge instable post-cutover ; loopback + hostPort k8s.
NEO4J_URI="${NEO4J_URI:-bolt://127.0.0.1:${BOLT_PORT}}"
LISTEN_ADDR="${NEO4J_EXPORTER_LISTEN_ADDRESS:-127.0.0.1:9217}"

docker rm -f wise-eat-neo4j-exporter 2>/dev/null || true

# host network : Bolt 127.0.0.1:7687 + metrics :9217 (pas de publish -p).
log "Recreate neo4j-exporter → ${NEO4J_URI} (listen ${LISTEN_ADDR}, network=host)"
docker run -d --name wise-eat-neo4j-exporter --restart unless-stopped \
  --network host \
  -e NEO4J_URI="${NEO4J_URI}" \
  -e NEO4J_USER="${NEO4J_USER}" \
  -e NEO4J_PASSWORD="${NEO4J_PASSWORD}" \
  -e NEO4J_EXPORTER_LISTEN_ADDRESS="${LISTEN_ADDR}" \
  "${EXPORTER_IMAGE}"

sleep 3
up="$(curl -sf "http://127.0.0.1:9217/metrics" 2>/dev/null | awk '/^neo4j_exporter_up /{print $2; exit}' || echo missing)"
if [[ "${up}" == "1" ]]; then
  log "OK  exporter :9217 neo4j_exporter_up=1"
else
  warn "FAIL neo4j_exporter_up=${up} — docker logs wise-eat-neo4j-exporter"
  docker logs wise-eat-neo4j-exporter --tail=25 2>&1 || true
fi

# Sync creds + URI monitoring pour futurs compose up (ne pas réintroduire host.docker.internal).
NEO4J_EXPORTER_LISTEN_ADDRESS="${LISTEN_ADDR}"
if [[ -f "${MON_ENV}" ]]; then
  for key in NEO4J_USER NEO4J_PASSWORD NEO4J_URI NEO4J_EXPORTER_LISTEN_ADDRESS; do
    val="${!key:-}"
    [[ -n "${val}" ]] || continue
    if grep -q "^${key}=" "${MON_ENV}" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${MON_ENV}"
    else
      echo "${key}=${val}" >> "${MON_ENV}"
    fi
  done
fi

log "Exporter Neo4j OK — job Prometheus :9217 inchangé"
