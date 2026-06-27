#!/usr/bin/env bash
# Build l'image Docker africa-meals-api et l'importe dans k3s (containerd).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=api-paths.sh
source "${SCRIPT_DIR}/api-paths.sh"

TAG="${1:-latest}"
IMAGE="africa-meals/api:${TAG}"
DOCKERFILE="$(cd "${SCRIPT_DIR}/.." && pwd)/Dockerfile.africa-meals-api"
BUILD_CTX=""
BUILD_CTX_TMP=""
API_DIR=""

cleanup() {
  [[ -n "${BUILD_CTX_TMP}" && -d "${BUILD_CTX_TMP}" ]] && rm -rf "${BUILD_CTX_TMP}"
}
trap cleanup EXIT

API_DIR="$(api_resolve_source_dir)" || {
  echo "Source API introuvable (wise-eat-api ou africa-meals-api avec package.json)." >&2
  echo "VPS : cloner le dépôt API dans /opt/wise-eat-api" >&2
  exit 1
}

if ! api_resolve_packages_dir "${API_DIR}" >/dev/null; then
  echo "packages/ introuvable (africa-meals-proto, africa-meals-field-selection)." >&2
  exit 1
fi

api_paths_init
BUILD_CTX="$(api_prepare_docker_context)"
if [[ "${BUILD_CTX}" != "${API_PATHS_MONO_ROOT}" ]]; then
  BUILD_CTX_TMP="${BUILD_CTX}"
fi

echo "Build ${IMAGE}"
echo "  source API : ${API_DIR}"
echo "  packages   : $(api_resolve_packages_dir "${API_DIR}")"
echo "  contexte   : ${BUILD_CTX}"

if [[ ! -f "${BUILD_CTX}/africa-meals-api/src/main.ts" ]]; then
  echo "Erreur : contexte Docker incomplet (africa-meals-api/src/main.ts absent)." >&2
  exit 1
fi

docker build -f "${DOCKERFILE}" -t "${IMAGE}" "${BUILD_CTX}"

if command -v k3s >/dev/null 2>&1; then
  echo "Import image dans k3s containerd..."
  docker save "${IMAGE}" | sudo k3s ctr images import -
  echo "Image importée : ${IMAGE}"
elif command -v ctr >/dev/null 2>&1 && [[ -S /run/k3s/containerd/containerd.sock ]]; then
  docker save "${IMAGE}" | sudo ctr -n k8s.io images import -
else
  echo "k3s absent — image Docker locale uniquement (${IMAGE})."
fi

echo "Terminé : ${IMAGE}"
