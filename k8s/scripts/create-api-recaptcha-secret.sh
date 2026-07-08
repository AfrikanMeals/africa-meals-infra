#!/usr/bin/env bash
# Secret Kubernetes pour le compte de service reCAPTCHA Enterprise (projet wise-eat-com).
# Distinct de accounts.json Firebase (wise-eat-com / FCM).
#
# Usage :
#   ./create-api-recaptcha-secret.sh /opt/wise-eat-api/recaptcha-accounts.json
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_API_RECAPTCHA_SECRET:-africa-meals-api-recaptcha-sa}"
SA_FILE="${1:-}"

if [[ -z "${SA_FILE}" || ! -f "${SA_FILE}" ]]; then
  echo "Fichier recaptcha-accounts.json absent — reCAPTCHA utilisera RECAPTCHA_ENTERPRISE_API_KEY ou ADC." >&2
  echo "Pour le SA wise-eat-com : Firebase Console (projet wise-eat-com) → Générer une clé privée →" >&2
  echo "  cp vers /opt/wise-eat-api/recaptcha-accounts.json puis relancer $0 <fichier>" >&2
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

"${KUBECTL[@]}" patch configmap africa-meals-api -n "${NAMESPACE}" --type merge \
  -p '{"data":{"RECAPTCHA_ENTERPRISE_SERVICE_ACCOUNT_PATH":"/run/secrets/recaptcha/accounts.json"}}'

echo "Secret ${SECRET_NAME} appliqué (wise-eat-com → /run/secrets/recaptcha/accounts.json)"
