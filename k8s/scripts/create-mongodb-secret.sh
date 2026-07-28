#!/usr/bin/env bash
# Crée le Secret K8s mongodb-config (creds + keyfile replica set).
# Source : mongodb/.env.mongodb + mongodb/keyfile — jamais de regen au cutover.
#
# Usage :
#   sudo ./create-mongodb-secret.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_MONGODB_SECRET:-mongodb-config}"
MONGODB_DIR="${MONGODB_DIR:-${INFRA_ROOT}/mongodb}"
MONGODB_ENV="${MONGODB_ENV:-${MONGODB_DIR}/.env.mongodb}"
KEYFILE="${MONGODB_KEYFILE:-${MONGODB_DIR}/keyfile}"

if [[ ! -f "${MONGODB_ENV}" ]]; then
  echo "Fichier absent : ${MONGODB_ENV} — sudo ./install.sh mongodb d'abord" >&2
  exit 1
fi
if [[ ! -f "${KEYFILE}" ]]; then
  echo "Keyfile absent : ${KEYFILE}" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

set -a
# shellcheck disable=SC1090
source "${MONGODB_ENV}"
set +a

: "${MONGO_ROOT_USER:?MONGO_ROOT_USER manquant}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD manquant}"
: "${MONGO_APP_USER:?MONGO_APP_USER manquant}"
: "${MONGO_APP_PASSWORD:?MONGO_APP_PASSWORD manquant}"
MONGO_APP_DATABASE="${MONGO_APP_DATABASE:-wise_eat_db}"
MONGO_REPLICA_SET="${MONGO_REPLICA_SET:-rs0}"

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

# Literals + fichier keyfile (évite parse env cassé sur mots de passe spéciaux).
"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-literal="MONGO_ROOT_USER=${MONGO_ROOT_USER}" \
  --from-literal="MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}" \
  --from-literal="MONGO_APP_USER=${MONGO_APP_USER}" \
  --from-literal="MONGO_APP_PASSWORD=${MONGO_APP_PASSWORD}" \
  --from-literal="MONGO_APP_DATABASE=${MONGO_APP_DATABASE}" \
  --from-literal="MONGO_REPLICA_SET=${MONGO_REPLICA_SET}" \
  --from-file="keyfile=${KEYFILE}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE}"
echo "  root=${MONGO_ROOT_USER} · app=${MONGO_APP_USER}@${MONGO_APP_DATABASE} · rs=${MONGO_REPLICA_SET}"
echo "  keyfile depuis ${KEYFILE}"
echo "  API : MONGODB_URI reste host.k3s.internal:27017 (directConnection)"
