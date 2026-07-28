#!/usr/bin/env bash
# Crée le Secret K8s minio-env depuis minio/.env.minio (creds prod inchangés).
# Ne commit jamais .env.minio — ce script lit le fichier hôte uniquement.
#
# Usage :
#   sudo ./create-minio-secret.sh
#   MINIO_ENV=/path/to/.env.minio ./create-minio-secret.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/env-file-sanitize.sh
source "${SCRIPT_DIR}/../../scripts/lib/env-file-sanitize.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_MINIO_SECRET:-minio-env}"
MINIO_ENV="${MINIO_ENV:-${INFRA_ROOT}/minio/.env.minio}"

if [[ ! -f "${MINIO_ENV}" ]]; then
  echo "Fichier absent : ${MINIO_ENV} — lancer d'abord sudo ./install.sh minio" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

# 1. Charger .env.minio (valeurs prod actuelles).
set -a
# shellcheck disable=SC1090
source "${MINIO_ENV}"
set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER manquant dans ${MINIO_ENV}}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD manquant dans ${MINIO_ENV}}"

# Défauts alignés docker-compose / .env.example (public HTTPS inchangé).
MINIO_SERVER_URL="${MINIO_SERVER_URL:-https://storage.wise-eat.com}"
MINIO_BROWSER_REDIRECT_URL="${MINIO_BROWSER_REDIRECT_URL:-https://cdn.wise-eat.com}"
MINIO_REPLICA_1_SERVER_URL="${MINIO_REPLICA_1_SERVER_URL:-https://dr1-storage.wise-eat.com}"
MINIO_REPLICA_2_SERVER_URL="${MINIO_REPLICA_2_SERVER_URL:-https://dr2-storage.wise-eat.com}"

FILTERED="$(mktemp)"
trap 'rm -f "${FILTERED}"' EXIT

# 2. Secret étroit — seulement les clés consommées par les Deployments MinIO.
cat > "${FILTERED}" <<EOF
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_SERVER_URL=${MINIO_SERVER_URL}
MINIO_BROWSER_REDIRECT_URL=${MINIO_BROWSER_REDIRECT_URL}
MINIO_REPLICA_1_SERVER_URL=${MINIO_REPLICA_1_SERVER_URL}
MINIO_REPLICA_2_SERVER_URL=${MINIO_REPLICA_2_SERVER_URL}
EOF

SANITIZED="$(mktemp)"
env_file_sanitize_file "${FILTERED}" "${SANITIZED}"
mv "${SANITIZED}" "${FILTERED}"

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-env-file="${FILTERED}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE} (depuis ${MINIO_ENV})"
