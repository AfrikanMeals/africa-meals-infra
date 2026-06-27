#!/usr/bin/env bash
# Applique les manifests k8s et vérifie le rollout (3 pods, PDB minAvailable=2).
#
# Usage :
#   ./deploy-ws.sh
#   ./deploy-ws.sh --build
#   ./deploy-ws.sh --verify
#   ./deploy-ws.sh --build --verify
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_WS_DIR="$(cd "${SCRIPT_DIR}/../africa-meals-ws" && pwd)"
DO_BUILD=false
DO_VERIFY=false

for arg in "$@"; do
  case "${arg}" in
    --build) DO_BUILD=true ;;
    --verify) DO_VERIFY=true ;;
    -h|--help)
      echo "Usage: $0 [--build] [--verify]"
      exit 0
      ;;
    --*)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

if [[ "${DO_BUILD}" == "true" ]]; then
  "${SCRIPT_DIR}/build-ws-image.sh"
fi

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_WS_SECRET:-africa-meals-ws-env}"
DEPLOYMENT="africa-meals-ws"

if ! "${KUBECTL[@]}" get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Secret ${SECRET_NAME} absent dans ${NAMESPACE}." >&2
  echo "Créer : ${SCRIPT_DIR}/create-ws-secret.sh /opt/wise-eat-ws/.env" >&2
  exit 1
fi

echo "Application kustomize (${K8S_WS_DIR})..."
"${KUBECTL[@]}" apply -k "${K8S_WS_DIR}"

echo "Rollout deployment/${DEPLOYMENT} (maxUnavailable=0, restartPolicy=Always)..."
"${KUBECTL[@]}" rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=300s

READY=$("${KUBECTL[@]}" get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}')
DESIRED=$("${KUBECTL[@]}" get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}')

if [[ "${READY:-0}" != "${DESIRED}" ]]; then
  echo "Erreur: ${READY:-0}/${DESIRED} pods ready" >&2
  "${KUBECTL[@]}" describe pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${DEPLOYMENT}" >&2 || true
  exit 1
fi

echo ""
echo "Synchronisation cibles Prometheus..."
"${SCRIPT_DIR}/sync-prometheus-ws-targets.sh" || true

echo ""
echo "Pods (${READY}/${DESIRED} ready) :"
"${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${DEPLOYMENT}" -o wide

echo ""
echo "PDB :"
"${KUBECTL[@]}" get pdb -n "${NAMESPACE}" 2>/dev/null || true

if [[ "${DO_VERIFY}" == "true" ]]; then
  echo ""
  echo "Sondate NodePort /api/health..."
  for i in 1 2 3 4 5; do
    if curl -sf --max-time 5 "http://127.0.0.1:30800/api/health" >/dev/null; then
      echo "OK — http://127.0.0.1:30800/api/health"
      curl -s "http://127.0.0.1:30800/api/health" | head -c 400
      echo ""
      exit 0
    fi
    sleep 3
  done
  echo "Échec sonde NodePort (nginx pas encore basculé ?)" >&2
  exit 1
fi

echo ""
echo "NodePort : http://127.0.0.1:30800/api/health"
echo "nginx    : sudo ${SCRIPT_DIR}/patch-nginx-ws-backend.sh"
