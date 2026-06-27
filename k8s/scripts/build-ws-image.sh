#!/usr/bin/env bash
# Build l'image Docker africa-meals-ws et l'importe dans k3s (containerd).
#
# Usage (depuis la racine du monorepo AfrikaMeals) :
#   ./infra/k8s/scripts/build-ws-image.sh
#   ./infra/k8s/scripts/build-ws-image.sh v1.2.3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_ROOT="$(cd "${K8S_DIR}/.." && pwd)"
MONO_ROOT="$(cd "${INFRA_ROOT}/.." && pwd)"

TAG="${1:-latest}"
IMAGE="africa-meals/ws:${TAG}"
DOCKERFILE="${K8S_DIR}/Dockerfile.africa-meals-ws"

if [[ ! -f "${MONO_ROOT}/africa-meals-ws/package.json" ]]; then
  echo "Monorepo introuvable — lancer depuis AfrikaMeals/ (parent de africa-meals-ws)." >&2
  exit 1
fi

echo "Build ${IMAGE} (contexte ${MONO_ROOT})..."
docker build -f "${DOCKERFILE}" -t "${IMAGE}" "${MONO_ROOT}"

if command -v k3s >/dev/null 2>&1; then
  echo "Import image dans k3s containerd..."
  docker save "${IMAGE}" | sudo k3s ctr images import -
  echo "Image importée : ${IMAGE}"
elif command -v ctr >/dev/null 2>&1 && [[ -S /run/k3s/containerd/containerd.sock ]]; then
  docker save "${IMAGE}" | sudo ctr -n k8s.io images import -
else
  echo "k3s absent — image Docker locale uniquement (${IMAGE})."
  echo "Sur le VPS : sudo k3s ctr images import - < <(docker save ${IMAGE})"
fi

echo "Terminé : ${IMAGE}"
