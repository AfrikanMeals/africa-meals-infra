#!/usr/bin/env bash
# Installe Headlamp (UI Kubernetes CNCF) dans le cluster k3s.
# Usage : sudo ./install-headlamp.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADLAMP_DIR="$(cd "${SCRIPT_DIR}/../headlamp" && pwd)"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

echo "Déploiement Headlamp (namespace headlamp, NodePort 30850)..."
"${KUBECTL[@]}" apply -k "${HEADLAMP_DIR}"
"${KUBECTL[@]}" rollout status deployment/headlamp -n headlamp --timeout=180s

echo ""
echo "Headlamp prêt — NodePort http://127.0.0.1:30850/"
echo "Token admin : sudo ${SCRIPT_DIR}/create-headlamp-admin-token.sh"
echo "Public      : sudo ${SCRIPT_DIR}/install-k8s-nginx.sh"
