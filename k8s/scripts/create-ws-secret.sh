#!/usr/bin/env bash
# Crée ou met à jour le Secret Kubernetes (mots de passe / JWT / URI).
# Réécrit les hostnames publics vers host.k3s.internal (services locaux VPS + TLS SNI via ConfigMap).
#
# Usage :
#   ./create-ws-secret.sh /opt/wise-eat-ws/.env
#   ./create-ws-secret.sh africa-meals-ws/.env
#   VPS_K8S_LOCAL=0 ./create-ws-secret.sh .env   # sans réécriture locale
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rewrite-k8s-mongodb-uri.sh
source "${SCRIPT_DIR}/lib/rewrite-k8s-mongodb-uri.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_WS_SECRET:-africa-meals-ws-env}"
ENV_FILE="${1:-}"
VPS_K8S_LOCAL="${VPS_K8S_LOCAL:-1}"
LOCAL_HOST="${VPS_LOCAL_HOST:-host.k3s.internal}"

if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
  echo "Usage: $0 <chemin/.env>" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

FILTERED="$(mktemp)"
trap 'rm -f "${FILTERED}"' EXIT

grep -E '^(MONGODB_URI|JWT_SECRET|INTERNAL_NOTIFY_SECRET|REDIS_URL|REDIS_USERNAME|REDIS_PASSWORD|REDIS_REPLICA_[12]_URL|BULLMQ_REDIS_URL|BULLMQ_REDIS_REPLICA_[12]_URL|MQTT_BROKER_PASSWORD|SUPPORT_STAFF_USER_ID|NEXT_PUBLIC_FCM_VAPID_KEY|DB_HOST|DB_USERNAME|DB_PASSWORD|DB_DATABASE)=' \
  "${ENV_FILE}" > "${FILTERED}" || true

if [[ ! -s "${FILTERED}" ]]; then
  echo "Aucune variable secrète reconnue dans ${ENV_FILE}" >&2
  exit 1
fi

if [[ "${VPS_K8S_LOCAL}" == "1" ]] && grep -qE '^MONGODB_URI=mongodb\+srv://' "${FILTERED}"; then
  echo "ATTENTION: MONGODB_URI Atlas (mongodb+srv) dans ${ENV_FILE}." >&2
  echo "En prod k8s sur le VPS, utilisez .env.prod (Mongo Stunnel host.k3s.internal:27018)." >&2
  echo "Le ConfigMap force MONGODB_TLS_SERVERNAME=db.wise-eat.com — incompatible avec Atlas." >&2
fi

if [[ "${VPS_K8S_LOCAL}" == "1" ]]; then
  REWRITTEN="$(mktemp)"
  sed \
    -e "s/@cache\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/@broker\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/@db\\.wise-eat\\.com:/@${LOCAL_HOST}:/g" \
    -e "s/cache\\.wise-eat\\.com:/${LOCAL_HOST}:/g" \
    -e "s/broker\\.wise-eat\\.com:/${LOCAL_HOST}:/g" \
    -e "s/db\\.wise-eat\\.com:/${LOCAL_HOST}:/g" \
    "${FILTERED}" > "${REWRITTEN}"
  mv "${REWRITTEN}" "${FILTERED}"
  rewrite_k8s_mongodb_uri_in_file "${FILTERED}" "${LOCAL_HOST}" "${MONGO_STUNNEL_PORT:-27018}"
fi

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-env-file="${FILTERED}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE} ($(wc -l < "${FILTERED}") clés, local=${VPS_K8S_LOCAL})"
