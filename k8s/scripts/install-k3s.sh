#!/usr/bin/env bash
# Installe k3s (Kubernetes léger) sur le VPS Wise Eat.
# Usage : sudo ./install-k3s.sh
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-}"
K3S_DISABLE_TRAEFIK="${K3S_DISABLE_TRAEFIK:-true}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

if command -v k3s >/dev/null 2>&1; then
  echo "k3s déjà installé : $(k3s --version)"
  exit 0
fi

echo "Installation k3s (Traefik désactivé — nginx hôte conserve 80/443)..."

install_args=(
  --write-kubeconfig-mode 644
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
echo "  ou      : sudo k3s kubectl get nodes"
echo ""
k3s kubectl get nodes
