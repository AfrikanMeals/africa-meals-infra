#!/usr/bin/env bash
# Crée le Secret K8s emqx-config depuis emqx/.env.emqx (cookie + dashboard).
# Les users MQTT (wise-eat-mqtt / wise-eat-admin) restent dans Mnesia (hostPath) + secrets API/WS.
#
# Usage :
#   sudo ./create-emqx-secret.sh
#   EMQX_ENV=/path/.env.emqx ./create-emqx-secret.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/env-file-sanitize.sh
source "${SCRIPT_DIR}/../../scripts/lib/env-file-sanitize.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_EMQX_SECRET:-emqx-config}"
EMQX_ENV="${EMQX_ENV:-${INFRA_ROOT}/emqx/.env.emqx}"

if [[ ! -f "${EMQX_ENV}" ]]; then
  echo "Fichier absent : ${EMQX_ENV} — lancer sudo ./install.sh emqx d'abord" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

set -a
# shellcheck disable=SC1090
source "${EMQX_ENV}"
set +a

: "${EMQX_ERLANG_COOKIE:?EMQX_ERLANG_COOKIE manquant dans ${EMQX_ENV}}"
: "${EMQX_DASHBOARD_PASSWORD:?EMQX_DASHBOARD_PASSWORD manquant dans ${EMQX_ENV}}"
EMQX_DASHBOARD_USERNAME="${EMQX_DASHBOARD_USERNAME:-admin}"

FILTERED="$(mktemp)"
trap 'rm -f "${FILTERED}"' EXIT

# Secret étroit — uniquement ce que les Deployments EMQX consomment.
cat > "${FILTERED}" <<EOF
EMQX_ERLANG_COOKIE=${EMQX_ERLANG_COOKIE}
EMQX_DASHBOARD_USERNAME=${EMQX_DASHBOARD_USERNAME}
EMQX_DASHBOARD_PASSWORD=${EMQX_DASHBOARD_PASSWORD}
EOF

SANITIZED="$(mktemp)"
env_file_sanitize_file "${FILTERED}" "${SANITIZED}"
mv "${SANITIZED}" "${FILTERED}"

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-env-file="${FILTERED}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE} (depuis ${EMQX_ENV})"
echo "  Cookie + dashboard inchangés vs Docker — users MQTT dans data-emqx-* / bootstrap-emqx-auth"
