#!/usr/bin/env bash
# Applique les manifests k8s et vérifie le rollout (HPA 3–5 pods, PDB minAvailable=2).
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

ws_print_rollout_diagnostics() {
  local ns="${1:-${NAMESPACE:-wise-eat}}"
  local app="${2:-${DEPLOYMENT:-africa-meals-ws}}"
  echo ""
  echo "=== Pods ==="
  "${KUBECTL[@]}" get pods -n "${ns}" -l "app.kubernetes.io/name=${app}" -o wide 2>/dev/null || true
  echo ""
  echo "=== Événements récents ==="
  "${KUBECTL[@]}" get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
  echo ""
  echo "=== describe (dernier pod) ==="
  local pod
  pod="$("${KUBECTL[@]}" get pods -n "${ns}" -l "app.kubernetes.io/name=${app}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    "${KUBECTL[@]}" describe pod "${pod}" -n "${ns}" 2>/dev/null | tail -80 || true
    echo ""
    echo "=== logs ${pod} (100 dernières lignes) ==="
    "${KUBECTL[@]}" logs "${pod}" -n "${ns}" --tail=100 2>/dev/null || true
  fi
}

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

echo "DNS host.k3s.internal → IP nœud VPS (k3s bare-metal)..."
"${SCRIPT_DIR}/ensure-k3s-host-gateway.sh"

echo "Rollout deployment/${DEPLOYMENT} (maxUnavailable=0, restartPolicy=Always)..."
if ! "${KUBECTL[@]}" rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=300s; then
  echo "Rollout timeout — aucun pod ready après 300s." >&2
  ws_print_rollout_diagnostics
  echo "" >&2
  echo "Pistes fréquentes :" >&2
  echo "  • Secret avec .env.prod (Mongo Stunnel host.k3s.internal), pas .env Atlas" >&2
  echo "  • Stunnel / Redis / Memcached actifs sur le VPS (ports 27018, 6381, 11212…)" >&2
  echo "  • host.k3s.internal : sudo ${SCRIPT_DIR}/ensure-k3s-host-gateway.sh" >&2
  exit 1
fi

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
