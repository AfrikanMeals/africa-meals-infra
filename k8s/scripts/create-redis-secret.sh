#!/usr/bin/env bash
# Génère ACL + confs replica (replicaof Services k8s) et Secret redis-config.
# Source de vérité mots de passe : redis/.env.redis (mêmes valeurs que Docker).
#
# Usage :
#   sudo ./create-redis-secret.sh
#   REDIS_ENV=/path/.env.redis ./create-redis-secret.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/env-file-sanitize.sh
source "${SCRIPT_DIR}/../../scripts/lib/env-file-sanitize.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_REDIS_SECRET:-redis-config}"
REDIS_ENV="${REDIS_ENV:-${INFRA_ROOT}/redis/.env.redis}"
# DNS in-cluster pour replicaof (plus wise-eat-redis-cache Docker).
CACHE_PRIMARY_HOST="${REDIS_CACHE_PRIMARY_HOST:-redis-cache.${NAMESPACE}.svc.cluster.local}"
BULL_PRIMARY_HOST="${REDIS_BULL_PRIMARY_HOST:-redis-bullmq.${NAMESPACE}.svc.cluster.local}"

if [[ ! -f "${REDIS_ENV}" ]]; then
  echo "Fichier absent : ${REDIS_ENV} — lancer sudo ./install.sh redis" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

set -a
# shellcheck disable=SC1090
source "${REDIS_ENV}"
set +a

: "${CACHE_REDIS_PASSWORD:?CACHE_REDIS_PASSWORD manquant dans ${REDIS_ENV}}"
: "${BULL_REDIS_PASSWORD:?BULL_REDIS_PASSWORD manquant dans ${REDIS_ENV}}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ACL identiques à install-redis.sh (user default off + app user).
cat > "${TMP}/cache-users.acl" <<EOF
user default off
user wise-eat-cache on >${CACHE_REDIS_PASSWORD} ~* &* +@all -flushall -flushdb -debug -config
EOF

cat > "${TMP}/bull-users.acl" <<EOF
user default off
user wise-eat-bull on >${BULL_REDIS_PASSWORD} ~* &* +@all -flushall -flushdb -debug -config
EOF

write_replica_conf() {
  local outfile="$1" primary_host="$2" master_user="$3" master_pass="$4" maxmem="$5" policy="$6"
  cat > "${outfile}" <<EOF
replicaof ${primary_host} 6379
masteruser ${master_user}
masterauth ${master_pass}
appendonly yes
appendfsync everysec
maxmemory ${maxmem}
maxmemory-policy ${policy}
tcp-keepalive 300
aclfile /etc/redis/users.acl
EOF
}

# replicaof → Service ClusterIP (joignable depuis pods réplicas).
write_replica_conf "${TMP}/cache-replica-1.conf" "${CACHE_PRIMARY_HOST}" wise-eat-cache "${CACHE_REDIS_PASSWORD}" 1024mb allkeys-lru
write_replica_conf "${TMP}/cache-replica-2.conf" "${CACHE_PRIMARY_HOST}" wise-eat-cache "${CACHE_REDIS_PASSWORD}" 1024mb allkeys-lru
write_replica_conf "${TMP}/bull-replica-1.conf" "${BULL_PRIMARY_HOST}" wise-eat-bull "${BULL_REDIS_PASSWORD}" 512mb noeviction
write_replica_conf "${TMP}/bull-replica-2.conf" "${BULL_PRIMARY_HOST}" wise-eat-bull "${BULL_REDIS_PASSWORD}" 512mb noeviction

# Mots de passe aussi en clés (probes / docs) — Secret, jamais ConfigMap.
printf '%s' "${CACHE_REDIS_PASSWORD}" > "${TMP}/CACHE_REDIS_PASSWORD"
printf '%s' "${BULL_REDIS_PASSWORD}" > "${TMP}/BULL_REDIS_PASSWORD"

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-file=cache-users.acl="${TMP}/cache-users.acl" \
  --from-file=bull-users.acl="${TMP}/bull-users.acl" \
  --from-file=cache-replica-1.conf="${TMP}/cache-replica-1.conf" \
  --from-file=cache-replica-2.conf="${TMP}/cache-replica-2.conf" \
  --from-file=bull-replica-1.conf="${TMP}/bull-replica-1.conf" \
  --from-file=bull-replica-2.conf="${TMP}/bull-replica-2.conf" \
  --from-file=CACHE_REDIS_PASSWORD="${TMP}/CACHE_REDIS_PASSWORD" \
  --from-file=BULL_REDIS_PASSWORD="${TMP}/BULL_REDIS_PASSWORD" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE}"
echo "  replicaof cache → ${CACHE_PRIMARY_HOST}:6379"
echo "  replicaof bull  → ${BULL_PRIMARY_HOST}:6379"
echo "  API : REDIS_PASSWORD / BULLMQ_REDIS_PASSWORD doivent matcher .env.redis"
