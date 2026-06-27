#!/usr/bin/env bash
# Affiche un token ServiceAccount pour connexion Headlamp (Auth → Token).
# Usage : sudo ./create-headlamp-admin-token.sh [durée]
set -euo pipefail

DURATION="${1:-8760h}"
NAMESPACE="headlamp"
SA="headlamp-admin"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

if ! "${KUBECTL[@]}" get sa "${SA}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ServiceAccount ${SA} absent — lancer install-headlamp.sh" >&2
  exit 1
fi

echo "Token Headlamp (${SA}, durée ${DURATION}) :"
echo ""
TOKEN="$("${KUBECTL[@]}" create token "${SA}" -n "${NAMESPACE}" --duration="${DURATION}")"
echo "${TOKEN}"
echo ""
echo "Dans https://k8s.wise-eat.com → Authentification → Token → coller le token ci-dessus."
