#!/usr/bin/env bash
# Secret Kubernetes pour accounts.json (Firebase / Google ADC).
# Usage : ./create-api-firebase-secret.sh /opt/wise-eat-api/accounts.json
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_API_FIREBASE_SECRET:-africa-meals-api-firebase-sa}"
SA_FILE="${1:-}"

if [[ -z "${SA_FILE}" || ! -f "${SA_FILE}" ]]; then
  echo "Fichier accounts.json absent — Firebase utilisera applicationDefault() (FCM optionnel)." >&2
  echo "Pour FCM : copier accounts.json puis relancer $0 /opt/wise-eat-api/accounts.json" >&2
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

if "${KUBECTL[@]}" get configmap africa-meals-api -n "${NAMESPACE}" >/dev/null 2>&1; then
  "${KUBECTL[@]}" patch configmap africa-meals-api -n "${NAMESPACE}" --type merge \
    -p '{"data":{"AM_FIREBASE_SERVICE_ACCOUNT_PATH":"/run/secrets/firebase/accounts.json"}}'
  echo "ConfigMap africa-meals-api : AM_FIREBASE_SERVICE_ACCOUNT_PATH activé"
else
  echo "ConfigMap africa-meals-api absent — patch Firebase reporté (après deploy-api)"
fi

# africa-meals-ws partage le même secret (App Check REST /api/chat/*).
if "${KUBECTL[@]}" get configmap africa-meals-ws -n "${NAMESPACE}" >/dev/null 2>&1; then
  "${KUBECTL[@]}" patch configmap africa-meals-ws -n "${NAMESPACE}" --type merge \
    -p '{"data":{"AM_FIREBASE_SERVICE_ACCOUNT_PATH":"/run/secrets/firebase/accounts.json","FIREBASE_SERVICE_ACCOUNT_PATH":"/run/secrets/firebase/accounts.json"}}'
  echo "ConfigMap africa-meals-ws : chemins Firebase App Check activés"
fi

echo "Secret ${SECRET_NAME} appliqué (accounts.json → /run/secrets/firebase/)"
echo "Redémarrer : kubectl rollout restart deployment/africa-meals-api deployment/africa-meals-ws -n ${NAMESPACE}"
