#!/usr/bin/env bash
# Secret Kubernetes pour accounts.json (Firebase / Google ADC).
# Usage : ./create-api-firebase-secret.sh /opt/wise-eat-api/accounts.json
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_API_FIREBASE_SECRET:-africa-meals-api-firebase-sa}"
SA_FILE="${1:-}"

if [[ -z "${SA_FILE}" || ! -f "${SA_FILE}" ]]; then
  echo "Usage: $0 <chemin/accounts.json>" >&2
  echo "Fichier absent — pods démarreront sans montage Firebase (optionnel)." >&2
  exit 0
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-file=accounts.json="${SA_FILE}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué (accounts.json)"
