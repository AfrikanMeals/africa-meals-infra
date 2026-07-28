#!/usr/bin/env bash
# Recrée mongodb-exporter → Mongo hostPort k8s (host.docker.internal:27017).
# Requis après cutover Mongo Docker → k8s (DNS wise-eat-mongo-1 mort).
# Metrics :127.0.0.1:9216 (job Prometheus inchangé).
#
# Usage :
#   sudo ./repair-mongodb-exporter-host.sh
#   sudo ./install.sh repair-mongodb-exporters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

MONGODB_ENV="${MONGODB_ENV:-${INFRA_ROOT}/mongodb/.env.mongodb}"
MON_ENV="${INFRA_ROOT}/monitoring/.env.monitoring"
EXPORTER_IMAGE="${MONGODB_EXPORTER_IMAGE:-percona/mongodb_exporter:0.44.0}"

[[ -f "${MONGODB_ENV}" ]] || die "Absent ${MONGODB_ENV}"
set -a
# shellcheck disable=SC1090
source "${MONGODB_ENV}"
[[ -f "${MON_ENV}" ]] && source "${MON_ENV}" || true
set +a

: "${MONGO_ROOT_USER:?}"
: "${MONGO_ROOT_PASSWORD:?}"
PRIMARY_PORT="${MONGO_PRIMARY_PORT:-27017}"

URI="mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@host.docker.internal:${PRIMARY_PORT}/admin?authSource=admin&directConnection=true"

docker rm -f wise-eat-mongodb-exporter 2>/dev/null || true

log "Recreate mongodb-exporter → host.docker.internal:${PRIMARY_PORT} (listen :9216)"
docker run -d --name wise-eat-mongodb-exporter --restart unless-stopped \
  --add-host=host.docker.internal:host-gateway \
  -p "127.0.0.1:9216:9216" \
  "${EXPORTER_IMAGE}" \
  --mongodb.uri="${URI}" \
  --mongodb.direct-connect \
  --mongodb.global-conn-pool \
  --mongodb.connect-timeout-ms=10000 \
  --compatible-mode \
  --collector.diagnosticdata \
  --collector.replicasetstatus \
  --collector.dbstats \
  --collector.topmetrics \
  --log.level=warn

sleep 4
if curl -sf http://127.0.0.1:9216/metrics 2>/dev/null | grep -qE '^mongodb_up |^mongodb_mongod_up '; then
  log "OK  exporter :9216 métriques mongodb_*"
else
  warn "FAIL exporter :9216 — docker logs wise-eat-mongodb-exporter"
  docker logs wise-eat-mongodb-exporter --tail=25 2>&1 || true
fi

# Sync creds monitoring
if [[ -f "${MON_ENV}" ]]; then
  for key in MONGO_ROOT_USER MONGO_ROOT_PASSWORD; do
    if grep -q "^${key}=" "${MON_ENV}" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${!key}|" "${MON_ENV}"
    else
      echo "${key}=${!key}" >> "${MON_ENV}"
    fi
  done
fi

log "Exporter MongoDB host OK — job Prometheus :9216 inchangé"
