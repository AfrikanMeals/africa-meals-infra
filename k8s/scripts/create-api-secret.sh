#!/usr/bin/env bash
# Crée ou met à jour le Secret Kubernetes depuis .env.prod (clés complètes).
# Réécrit les hostnames publics vers host.k3s.internal pour les services VPS locaux.
#
# Usage :
#   ./create-api-secret.sh /opt/wise-eat-api/.env.prod
#   VPS_K8S_LOCAL=0 ./create-api-secret.sh .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rewrite-k8s-mongodb-uri.sh
source "${SCRIPT_DIR}/lib/rewrite-k8s-mongodb-uri.sh"
# shellcheck source=../../scripts/lib/env-file-sanitize.sh
source "${SCRIPT_DIR}/../../scripts/lib/env-file-sanitize.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_API_SECRET:-africa-meals-api-env}"
ENV_FILE="${1:-}"
VPS_K8S_LOCAL="${VPS_K8S_LOCAL:-1}"
LOCAL_HOST="${VPS_LOCAL_HOST:-host.k3s.internal}"

if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
  echo "Usage: $0 <chemin/.env.prod>" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

FILTERED="$(mktemp)"
trap 'rm -f "${FILTERED}"' EXIT

RAW="$(mktemp)"
SANITIZED="$(mktemp)"
grep -vE '^\s*(#|$)' "${ENV_FILE}" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' > "${RAW}" || true
env_file_sanitize_file "${RAW}" "${SANITIZED}"
mv "${SANITIZED}" "${RAW}"

if [[ ! -s "${RAW}" ]]; then
  echo "Aucune variable dans ${ENV_FILE}" >&2
  exit 1
fi

# kubectl --from-env-file refuse les clés dupliquées (ex. APP_NAME, SUPPORT_EMAIL).
# Dernière occurrence dans le fichier = valeur retenue (comportement .env habituel).
BEFORE_DEDUPE="$(wc -l < "${RAW}" | tr -d ' ')"
tac "${RAW}" | awk '
  /^[A-Za-z_][A-Za-z0-9_]*=/ {
    key = $0
    sub(/=.*/, "", key)
    if (!seen[key]++) print
  }
' | tac > "${FILTERED}"
rm -f "${RAW}"
AFTER_DEDUPE="$(wc -l < "${FILTERED}" | tr -d ' ')"
if [[ "${BEFORE_DEDUPE}" != "${AFTER_DEDUPE}" ]]; then
  echo "Clés dupliquées ignorées (${BEFORE_DEDUPE} → ${AFTER_DEDUPE} entrées uniques, dernière valeur gardée)." >&2
fi

if [[ "${VPS_K8S_LOCAL}" == "1" ]] && grep -qE '^MONGODB_URI=mongodb\+srv://' "${FILTERED}"; then
  echo "ATTENTION: MONGODB_URI Atlas (mongodb+srv) dans ${ENV_FILE}." >&2
  echo "En prod k8s sur le VPS, utilisez .env.prod (Mongo local ${LOCAL_HOST}:27017|27027|27028)." >&2
fi

if [[ "${VPS_K8S_LOCAL}" == "1" ]]; then
  REWRITTEN="$(mktemp)"
  sed \
    -e "s/@cache\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/@broker\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/@db\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/@storage\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/cache\\.wise-eat\\.com:/${LOCAL_HOST}:/g" \
    -e "s/broker\\.wise-eat\\.com:/${LOCAL_HOST}:/g" \
    -e "s/db\\.wise-eat\\.com:/${LOCAL_HOST}:/g" \
    -e "s/127\\.0\\.0\\.1:9401/${LOCAL_HOST}:9401/g" \
    -e "s/127\\.0\\.0\\.1:11434/${LOCAL_HOST}:11434/g" \
    "${FILTERED}" > "${REWRITTEN}"
  mv "${REWRITTEN}" "${FILTERED}"
  rewrite_k8s_mongodb_uri_in_file "${FILTERED}" "${LOCAL_HOST}"
  rewrite_k8s_redis_urls_in_file "${FILTERED}" "${LOCAL_HOST}"
  # Secret gagne sur ConfigMap (envFrom order) — forcer plaintext local
  {
    grep -vE '^(REDIS_TLS|REDIS_TLS_REJECT_UNAUTHORIZED|REDIS_TLS_SERVERNAME|REDIS_PORT|REDIS_HOST|REDIS_REPLICA_1_PORT|REDIS_REPLICA_2_PORT|BULLMQ_REDIS_TLS|BULLMQ_REDIS_TLS_REJECT_UNAUTHORIZED|BULLMQ_REDIS_TLS_SERVERNAME|BULLMQ_REDIS_PORT|BULLMQ_REDIS_HOST|BULLMQ_REDIS_REPLICA_1_PORT|BULLMQ_REDIS_REPLICA_2_PORT|MEMCACHED_TLS|MEMCACHED_TLS_REJECT_UNAUTHORIZED|MEMCACHED_TLS_SERVERNAME|MEMCACHED_SERVERS|MEMCACHED_REPLICA_1_SERVERS|MEMCACHED_REPLICA_2_SERVERS|MONGODB_TLS_SERVERNAME)=' "${FILTERED}" || true
    cat <<EOF
REDIS_HOST=${LOCAL_HOST}
REDIS_PORT=6379
REDIS_TLS=false
REDIS_REPLICA_1_PORT=6371
REDIS_REPLICA_2_PORT=6372
BULLMQ_REDIS_HOST=${LOCAL_HOST}
BULLMQ_REDIS_PORT=6380
BULLMQ_REDIS_TLS=false
BULLMQ_REDIS_REPLICA_1_PORT=6390
BULLMQ_REDIS_REPLICA_2_PORT=6391
MEMCACHED_SERVERS=${LOCAL_HOST}:11211
MEMCACHED_TLS=false
MEMCACHED_REPLICA_1_SERVERS=${LOCAL_HOST}:11213
MEMCACHED_REPLICA_2_SERVERS=${LOCAL_HOST}:11214
EOF
  } > "${FILTERED}.local"
  mv "${FILTERED}.local" "${FILTERED}"
fi

# GOOGLE_APPLICATION_CREDENTIALS=accounts.json (PM2 local) — remplacé par ConfigMap k8s + volume /run/secrets/firebase
grep -vE '^GOOGLE_APPLICATION_CREDENTIALS=' "${FILTERED}" > "${FILTERED}.strip" || true
mv "${FILTERED}.strip" "${FILTERED}"

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-env-file="${FILTERED}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE} ($(wc -l < "${FILTERED}") clés, local=${VPS_K8S_LOCAL})"
