#!/usr/bin/env bash
# Applique les manifests k8s API et vérifie le rollout (HPA 5–10 pods, PDB minAvailable=3).
#
# Usage :
#   ./deploy-api.sh
#   ./deploy-api.sh --build
#   ./deploy-api.sh --verify
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_API_DIR="$(cd "${SCRIPT_DIR}/../africa-meals-api" && pwd)"
DO_BUILD=false
DO_VERIFY=false
SKIP_CLEANUP=false

for arg in "$@"; do
  case "${arg}" in
    --build) DO_BUILD=true ;;
    --verify) DO_VERIFY=true ;;
    --skip-cleanup) SKIP_CLEANUP=true ;;
    -h|--help)
      echo "Usage: $0 [--build] [--verify] [--skip-cleanup]"
      exit 0
      ;;
    --*)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

run_disk_cleanup() {
  if [[ "${SKIP_CLEANUP}" == "false" ]]; then
    echo ""
    echo "Nettoyage disque post-déploiement..."
    "${SCRIPT_DIR}/lib/post-deploy-disk-cleanup.sh" api || true
  fi
}

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

api_print_rollout_diagnostics() {
  local ns="${1:-${NAMESPACE:-wise-eat}}"
  local app="${2:-${DEPLOYMENT:-africa-meals-api}}"
  echo ""
  echo "=== Pods ==="
  "${KUBECTL[@]}" get pods -n "${ns}" -l "app.kubernetes.io/name=${app}" -o wide 2>/dev/null || true
  echo ""
  echo "=== Événements récents ==="
  "${KUBECTL[@]}" get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
  echo ""
  local pod
  pod="$("${KUBECTL[@]}" get pods -n "${ns}" -l "app.kubernetes.io/name=${app}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    echo "=== logs ${pod} (100 dernières lignes) ==="
    "${KUBECTL[@]}" logs "${pod}" -n "${ns}" --tail=100 2>/dev/null || true
  fi
}

if [[ "${DO_BUILD}" == "true" ]]; then
  "${SCRIPT_DIR}/build-api-image.sh"
fi

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_API_SECRET:-africa-meals-api-env}"
DEPLOYMENT="africa-meals-api"

if ! "${KUBECTL[@]}" get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Secret ${SECRET_NAME} absent dans ${NAMESPACE}." >&2
  echo "Créer : ${SCRIPT_DIR}/create-api-secret.sh /opt/wise-eat-api/.env.prod" >&2
  exit 1
fi

echo "Application kustomize (${K8S_API_DIR})..."
"${KUBECTL[@]}" apply -k "${K8S_API_DIR}"

echo "DNS host.k3s.internal → IP nœud VPS..."
"${SCRIPT_DIR}/ensure-k3s-host-gateway.sh"

echo "Rollout deployment/${DEPLOYMENT} (maxUnavailable=0, restartPolicy=Always)..."
if ! "${KUBECTL[@]}" rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=600s; then
  echo "Rollout timeout — aucun pod ready après 600s." >&2
  api_print_rollout_diagnostics
  exit 1
fi

READY=$("${KUBECTL[@]}" get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}')
DESIRED=$("${KUBECTL[@]}" get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}')

if [[ "${READY:-0}" != "${DESIRED}" ]]; then
  echo "Erreur: ${READY:-0}/${DESIRED} pods ready" >&2
  exit 1
fi

echo ""
echo "Synchronisation cibles Prometheus..."
"${SCRIPT_DIR}/sync-prometheus-api-targets.sh" || true

echo ""
echo "Pods (${READY}/${DESIRED} ready) :"
"${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${DEPLOYMENT}" -o wide

echo ""
echo "PDB :"
"${KUBECTL[@]}" get pdb -n "${NAMESPACE}" -l app.kubernetes.io/name="${DEPLOYMENT}" 2>/dev/null || true

echo ""
echo "metrics-server (requis HPA)..."
"${SCRIPT_DIR}/ensure-metrics-server.sh" || true

echo ""
echo "HPA :"
"${KUBECTL[@]}" get hpa "${DEPLOYMENT}" -n "${NAMESPACE}" 2>/dev/null || true
HPA_MIN=$("${KUBECTL[@]}" get hpa "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "")
HPA_MAX=$("${KUBECTL[@]}" get hpa "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "")
if [[ -n "${HPA_MIN}" && -n "${HPA_MAX}" ]]; then
  echo "Autoscaling actif : ${HPA_MIN}–${HPA_MAX} pods (CPU 70 %, mémoire 80 %)"
fi

if [[ "${DO_VERIFY}" == "true" ]]; then
  echo ""
  echo "Sondate NodePort /api/health..."
  for i in 1 2 3 4 5 6; do
    if curl -sf --max-time 8 "http://127.0.0.1:30900/api/health" >/dev/null; then
      echo "OK — http://127.0.0.1:30900/api/health"
      curl -s "http://127.0.0.1:30900/api/health" | head -c 400
      echo ""
      run_disk_cleanup
      exit 0
    fi
    sleep 5
  done
  echo "Échec sonde NodePort (nginx pas encore basculé ?)" >&2
  exit 1
fi

echo ""
echo "NodePort : http://127.0.0.1:30900/api/health"
echo "nginx    : sudo ${SCRIPT_DIR}/patch-nginx-api-backend.sh"
run_disk_cleanup
