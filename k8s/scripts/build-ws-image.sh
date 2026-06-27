#!/usr/bin/env bash
# Build l'image Docker africa-meals-ws et l'importe dans k3s (containerd).
#
# Monorepo (AfrikaMeals/) :
#   ./infra/k8s/scripts/build-ws-image.sh
#
# VPS (/opt/wise-eat + /opt/wise-eat-ws + /opt/packages) :
#   sudo ./k8s/scripts/build-ws-image.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ws-paths.sh
source "${SCRIPT_DIR}/ws-paths.sh"

TAG="${1:-latest}"
IMAGE="africa-meals/ws:${TAG}"
DOCKERFILE="$(cd "${SCRIPT_DIR}/.." && pwd)/Dockerfile.africa-meals-ws"
BUILD_CTX=""
BUILD_CTX_TMP=""
WS_DIR=""

cleanup() {
  [[ -n "${BUILD_CTX_TMP}" && -d "${BUILD_CTX_TMP}" ]] && rm -rf "${BUILD_CTX_TMP}"
}
trap cleanup EXIT

WS_DIR="$(ws_resolve_source_dir)" || {
  echo "Source WS introuvable (wise-eat-ws ou africa-meals-ws avec package.json)." >&2
  echo "VPS : cloner le dépôt WS dans /opt/wise-eat-ws" >&2
  exit 1
}

if ! ws_resolve_packages_dir "${WS_DIR}" >/dev/null; then
  echo "packages/ introuvable (africa-meals-proto, africa-meals-field-selection)." >&2
  echo "VPS : cloner ou lier packages/ à côté de wise-eat-ws (ex. /opt/packages)." >&2
  exit 1
fi

ws_paths_init
BUILD_CTX="$(ws_prepare_docker_context)"
if [[ "${BUILD_CTX}" != "${WS_PATHS_MONO_ROOT}" ]]; then
  BUILD_CTX_TMP="${BUILD_CTX}"
fi

echo "Build ${IMAGE}"
echo "  source WS : ${WS_DIR}"
echo "  contexte  : ${BUILD_CTX}"
docker build -f "${DOCKERFILE}" -t "${IMAGE}" "${BUILD_CTX}"

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
