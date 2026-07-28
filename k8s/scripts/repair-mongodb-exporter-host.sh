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

# Encode user/pass (sinon @ : / dans le mot de passe → URI invalide → pas de mongodb_up).
export PRIMARY_PORT
URI="$(python3 - <<'PY'
import urllib.parse, os
u = urllib.parse.quote(os.environ["MONGO_ROOT_USER"], safe="")
p = urllib.parse.quote(os.environ["MONGO_ROOT_PASSWORD"], safe="")
port = os.environ.get("PRIMARY_PORT", "27017")
print(f"mongodb://{u}:{p}@host.docker.internal:{port}/admin?authSource=admin&directConnection=true")
PY
)"

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

sleep 6
METRICS="$(curl -sf http://127.0.0.1:9216/metrics 2>/dev/null || true)"
if echo "${METRICS}" | grep -qE '^mongodb_up |^mongodb_mongod_up '; then
  log "OK  exporter :9216 métriques mongodb_*"
elif [[ -z "${METRICS}" ]]; then
  warn "FAIL :9216 vide / injoignable — docker logs wise-eat-mongodb-exporter"
  docker logs wise-eat-mongodb-exporter --tail=40 2>&1 || true
  # Fallback réseau host (hostPort 127.0.0.1 parfois hors host-gateway).
  warn "Retry exporter en --network host → 127.0.0.1:${PRIMARY_PORT}"
  docker rm -f wise-eat-mongodb-exporter 2>/dev/null || true
  URI_HOST="$(python3 - <<'PY'
import urllib.parse, os
u = urllib.parse.quote(os.environ["MONGO_ROOT_USER"], safe="")
p = urllib.parse.quote(os.environ["MONGO_ROOT_PASSWORD"], safe="")
port = os.environ.get("PRIMARY_PORT", "27017")
print(f"mongodb://{u}:{p}@127.0.0.1:{port}/admin?authSource=admin&directConnection=true")
PY
)"
  docker run -d --name wise-eat-mongodb-exporter --restart unless-stopped \
    --network host \
    "${EXPORTER_IMAGE}" \
    --mongodb.uri="${URI_HOST}" \
    --mongodb.direct-connect \
    --mongodb.global-conn-pool \
    --mongodb.connect-timeout-ms=10000 \
    --compatible-mode \
    --collector.diagnosticdata \
    --collector.replicasetstatus \
    --collector.dbstats \
    --collector.topmetrics \
    --web.listen-address=":9216" \
    --log.level=warn
  sleep 6
  if curl -sf http://127.0.0.1:9216/metrics 2>/dev/null | grep -qE '^mongodb_up |^mongodb_mongod_up '; then
    log "OK  exporter host-network :9216"
  else
    warn "FAIL exporter — docker logs wise-eat-mongodb-exporter"
    docker logs wise-eat-mongodb-exporter --tail=40 2>&1 || true
  fi
else
  warn "FAIL pas de mongodb_up dans /metrics — sample :"
  echo "${METRICS}" | grep -iE 'mongo|up|error' | head -20 || true
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

log "Exporter MongoDB : job Prometheus :9216 inchangé"
