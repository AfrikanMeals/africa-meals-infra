#!/usr/bin/env bash
# host.k3s.internal n'existe pas nativement sur k3s bare-metal (réservé à k3d).
# Ce script :
#   1. CoreDNS custom → host.k3s.internal → InternalIP du nœud
#   2. hostAliases sur le Deployment WS (résolution DNS même si CoreDNS en panne)
#
# Usage : sudo ./ensure-k3s-host-gateway.sh
set -euo pipefail

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
DEPLOYMENT="${K8S_WS_DEPLOYMENT:-africa-meals-ws}"
HOSTNAME="${VPS_LOCAL_HOST:-host.k3s.internal}"

NODE_IP="$("${KUBECTL[@]}" get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1 || true)"

if [[ -z "${NODE_IP}" ]]; then
  echo "Impossible de lire InternalIP d'un nœud k3s (kubectl get nodes)." >&2
  exit 1
fi

echo "Passerelle hôte k3s : ${HOSTNAME} → ${NODE_IP}"

"${KUBECTL[@]}" create namespace kube-system --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

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

if ! echo "${COREDNS_PATCH}" | "${KUBECTL[@]}" apply -f -; then
  echo "Échec application coredns-custom" >&2
  exit 1
fi

if "${KUBECTL[@]}" get deployment coredns -n kube-system >/dev/null 2>&1; then
  "${KUBECTL[@]}" rollout restart deployment/coredns -n kube-system >/dev/null 2>&1 || true
  "${KUBECTL[@]}" rollout status deployment/coredns -n kube-system --timeout=120s >/dev/null 2>&1 || true
fi

if "${KUBECTL[@]}" get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  "${KUBECTL[@]}" patch deployment "${DEPLOYMENT}" -n "${NAMESPACE}" --type=strategic --patch "$(cat <<EOF
spec:
  template:
    spec:
      hostAliases:
        - ip: "${NODE_IP}"
          hostnames:
            - "${HOSTNAME}"
EOF
)"
  echo "hostAliases appliqués sur deployment/${DEPLOYMENT} (${NAMESPACE})"
fi

echo "OK — ${HOSTNAME} pointe vers ${NODE_IP} (Stunnel écoute 0.0.0.0 sur le VPS)"
