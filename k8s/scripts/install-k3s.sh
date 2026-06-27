#!/usr/bin/env bash
# Installe k3s production (Traefik off, swap hôte, kubelet fail-swap-on=false).
# Usage : sudo ./install-k3s.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

K3S_VERSION="${K3S_VERSION:-}"
K3S_DISABLE_TRAEFIK="${K3S_DISABLE_TRAEFIK:-true}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

if [[ -f "${INFRA_ROOT}/scripts/lib/vps-swap.sh" ]]; then
  # shellcheck source=../../scripts/lib/vps-swap.sh
  source "${INFRA_ROOT}/scripts/lib/vps-swap.sh"
  ensure_vps_swap
fi

if command -v k3s >/dev/null 2>&1; then
  echo "k3s déjà installé : $(k3s --version)"
  exit 0
fi

echo "Installation k3s production (nginx hôte 80/443, swap VPS activé)..."

install_args=(
  --write-kubeconfig-mode 644
  --kubelet-arg=fail-swap-on=false
  '--kubelet-arg=eviction-hard=memory.available<100Mi'
  '--kubelet-arg=eviction-soft=memory.available<200Mi'
  '--kubelet-arg=eviction-soft-grace-period=memory.available=30s'
)

if [[ "${K3S_DISABLE_TRAEFIK}" == "true" ]]; then
  install_args+=(--disable traefik)
fi

if [[ -n "${K3S_VERSION}" ]]; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - "${install_args[@]}"
else
  curl -sfL https://get.k3s.io | sh -s - "${install_args[@]}"
fi

echo ""
echo "k3s installé."
echo "  kubectl : export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo "  swap    : swapon --show"
echo ""
k3s kubectl get nodes
swapon --show 2>/dev/null || true
