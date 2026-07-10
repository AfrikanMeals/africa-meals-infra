#!/usr/bin/env bash
# host.k3s.internal n'existe pas nativement sur k3s bare-metal (réservé à k3d).
#
# Mécanisme principal (fiable) : hostAliases sur les Deployments WS/API → /etc/hosts du pod.
# CoreDNS custom (optionnel) : ENABLE_COREDNS_HOST_GATEWAY=1 — peut casser CoreDNS si mal configuré.
#
# Important : ne PAS mapper vers l'InternalIP publique du VPS (ex. 2.24.x.x) —
# les pods qui joignent l'IP publique du même hôte subissent un hairpin NAT → ECONNRESET
# (Mongo :27018, Redis Stunnel, etc.). Préférer l'IP du bridge CNI (cni0, souvent 10.42.0.1).
#
# Usage :
#   sudo ./ensure-k3s-host-gateway.sh
#   sudo K3S_HOST_GATEWAY_IP=10.42.0.1 ./ensure-k3s-host-gateway.sh
#   sudo ./ensure-k3s-host-gateway.sh --repair-coredns
set -euo pipefail

REPAIR_COREDNS=false
for arg in "$@"; do
  case "${arg}" in
    --repair-coredns) REPAIR_COREDNS=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ensure-k3s-host-gateway.sh [--repair-coredns]

  hostAliases sur africa-meals-ws et africa-meals-api (défaut, recommandé)
  IP : cni0 / flannel (évite hairpin) — override K3S_HOST_GATEWAY_IP=

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

is_rfc1918_ipv4() {
  local ip="${1:-}"
  case "${ip}" in
    10.*|192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

# IP joignable depuis les pods vers les services hôte (Stunnel 0.0.0.0).
resolve_k3s_host_gateway_ip() {
  local ip=""

  if [[ -n "${K3S_HOST_GATEWAY_IP:-}" ]]; then
    printf '%s\n' "${K3S_HOST_GATEWAY_IP}"
    return 0
  fi

  # Bridge CNI k3s (flannel) — typiquement 10.42.0.1 ; pas de hairpin public.
  local iface
  for iface in cni0 flannel.1; do
    ip="$(ip -4 addr show "${iface}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1 || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
  done

  # Fallback : premier hôte du podCIDR nœud (…0/24 → …1).
  local cidr base
  cidr="$("${KUBECTL[@]}" get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)"
  if [[ "${cidr}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0/([0-9]+)$ ]]; then
    base="${BASH_REMATCH[1]}"
    printf '%s.1\n' "${base}"
    return 0
  fi

  local node_ip
  node_ip="$("${KUBECTL[@]}" get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1 || true)"
  if [[ -n "${node_ip}" ]] && is_rfc1918_ipv4 "${node_ip}"; then
    printf '%s\n' "${node_ip}"
    return 0
  fi

  if [[ -n "${node_ip}" ]]; then
    echo "ATTENTION: InternalIP ${node_ip} est publique — hairpin NAT probable (ECONNRESET Mongo/Redis)." >&2
    echo "  Installez/vérifiez cni0, ou forcez : K3S_HOST_GATEWAY_IP=10.42.0.1 $0" >&2
    printf '%s\n' "${node_ip}"
    return 0
  fi

  return 1
}

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

GATEWAY_IP="$(resolve_k3s_host_gateway_ip || true)"
if [[ -z "${GATEWAY_IP}" ]]; then
  echo "Impossible de résoudre l'IP passerelle hôte k3s (cni0 / podCIDR / InternalIP)." >&2
  exit 1
fi

echo "Passerelle hôte k3s : ${HOSTNAME} → ${GATEWAY_IP}"
if ! is_rfc1918_ipv4 "${GATEWAY_IP}"; then
  echo "ATTENTION: ${GATEWAY_IP} n'est pas RFC1918 — risque ECONNRESET (hairpin) depuis les pods." >&2
fi

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
      ${GATEWAY_IP} ${HOSTNAME}
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
        - ip: "${GATEWAY_IP}"
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

echo "OK — ${HOSTNAME} → ${GATEWAY_IP} via /etc/hosts des pods WS/API (Stunnel 0.0.0.0 sur le VPS)"
echo ""
echo "Vérifier depuis un pod :"
echo "  kubectl -n ${NAMESPACE} exec deploy/africa-meals-ws -- getent hosts ${HOSTNAME}"
echo "  # attendu : ${GATEWAY_IP}  ${HOSTNAME}"
echo ""
echo "Note : un pod debug (kubectl run dns-test) n'a pas ces hostAliases —"
echo "       tester : curl http://127.0.0.1:30800/api/health (WS) ou :30900/api/health (API)"
