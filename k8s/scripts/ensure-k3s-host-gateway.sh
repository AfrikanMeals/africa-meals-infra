#!/usr/bin/env bash
# host.k3s.internal n'existe pas nativement sur k3s bare-metal (réservé à k3d).
#
# Mécanisme principal (fiable) : hostAliases sur le Deployment WS → /etc/hosts du pod.
# CoreDNS custom (optionnel) : ENABLE_COREDNS_HOST_GATEWAY=1 — peut casser CoreDNS si mal configuré.
#
# Usage :
#   sudo ./ensure-k3s-host-gateway.sh
#   sudo ./ensure-k3s-host-gateway.sh --repair-coredns   # supprime coredns-custom + redémarre CoreDNS
set -euo pipefail

REPAIR_COREDNS=false
for arg in "$@"; do
  case "${arg}" in
    --repair-coredns) REPAIR_COREDNS=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ensure-k3s-host-gateway.sh [--repair-coredns]

  hostAliases sur africa-meals-ws et africa-meals-api (défaut, recommandé)

  --repair-coredns  Supprime coredns-custom (host-gateway) et redémarre CoreDNS
EOF
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

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
HOSTNAME="${VPS_LOCAL_HOST:-host.k3s.internal}"
ENABLE_COREDNS="${ENABLE_COREDNS_HOST_GATEWAY:-0}"
DEPLOYMENTS=(
  "${K8S_WS_DEPLOYMENT:-africa-meals-ws}"
  "${K8S_API_DEPLOYMENT:-africa-meals-api}"
)

ws_restart_coredns() {
  if "${KUBECTL[@]}" get deployment coredns -n kube-system >/dev/null 2>&1; then
    "${KUBECTL[@]}" rollout restart deployment/coredns -n kube-system
    "${KUBECTL[@]}" rollout status deployment/coredns -n kube-system --timeout=120s
  fi
}

if [[ "${REPAIR_COREDNS}" == "true" ]]; then
  echo "Réparation CoreDNS (suppression coredns-custom)..."
  "${KUBECTL[@]}" delete configmap coredns-custom -n kube-system --ignore-not-found
  ws_restart_coredns
  echo "CoreDNS redémarré. Vérifier : kubectl get pods -n kube-system -l k8s-app=kube-dns"
  exit 0
fi

NODE_IP="$("${KUBECTL[@]}" get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1 || true)"

if [[ -z "${NODE_IP}" ]]; then
  echo "Impossible de lire InternalIP d'un nœud k3s (kubectl get nodes)." >&2
  exit 1
fi

echo "Passerelle hôte k3s : ${HOSTNAME} → ${NODE_IP}"

if [[ "${ENABLE_COREDNS}" == "1" ]]; then
  echo "CoreDNS custom activé (ENABLE_COREDNS_HOST_GATEWAY=1)..."
  COREDNS_PATCH="$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  host-gateway.override: |
    hosts {
      ${NODE_IP} ${HOSTNAME}
      fallthrough
    }
EOF
)"
  echo "${COREDNS_PATCH}" | "${KUBECTL[@]}" apply -f -
  ws_restart_coredns || echo "Attention: CoreDNS n'a pas redémarré proprement." >&2
else
  echo "CoreDNS non modifié (hostAliases suffisent pour les pods WS/API)."
  echo "  Réparer CoreDNS cassé : sudo $0 --repair-coredns"
fi

HOST_ALIAS_PATCH="$(cat <<EOF
spec:
  template:
    spec:
      hostAliases:
        - ip: "${NODE_IP}"
          hostnames:
            - "${HOSTNAME}"
EOF
)"

for DEPLOYMENT in "${DEPLOYMENTS[@]}"; do
  if "${KUBECTL[@]}" get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    "${KUBECTL[@]}" patch deployment "${DEPLOYMENT}" -n "${NAMESPACE}" --type=strategic --patch "${HOST_ALIAS_PATCH}"
    echo "hostAliases appliqués sur deployment/${DEPLOYMENT} (${NAMESPACE})"
  fi
done

echo "OK — ${HOSTNAME} → ${NODE_IP} via /etc/hosts des pods WS/API (Stunnel 0.0.0.0 sur le VPS)"
echo ""
echo "Note : un pod debug (kubectl run dns-test) n'a pas ces hostAliases —"
echo "       tester : curl http://127.0.0.1:30800/api/health (WS) ou :30900/api/health (API)"
