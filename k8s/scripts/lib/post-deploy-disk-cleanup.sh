#!/usr/bin/env bash
# Réclamation d'espace disque après déploiement API/WS (Docker build + import k3s).
#
# Usage :
#   sudo post-deploy-disk-cleanup.sh [api|ws|all]
#
# Variables :
#   DEPLOY_CLEANUP_KEEP_BUILD_CACHE_GB  — cache BuildKit à conserver (défaut 2)
#   DEPLOY_CLEANUP_DRY_RUN=1            — afficher sans exécuter
set -euo pipefail

SERVICE="${1:-all}"
KEEP_BUILD_CACHE_GB="${DEPLOY_CLEANUP_KEEP_BUILD_CACHE_GB:-2}"
DRY_RUN="${DEPLOY_CLEANUP_DRY_RUN:-0}"

case "${SERVICE}" in
  api|ws|all) ;;
  -h|--help)
    cat <<'EOF'
Usage: sudo post-deploy-disk-cleanup.sh [api|ws|all]

Nettoie en toute sécurité après un déploiement réussi :
  • artefacts /tmp des scripts deploy
  • cache BuildKit Docker (conserve DEPLOY_CLEANUP_KEEP_BUILD_CACHE_GB GiB)
  • images Docker dangling
  • pods arrêtés + images containerd/k3s inutilisées (crictl)

Ne supprime pas les images/volumes des conteneurs Docker actifs (monitoring, Mongo, MinIO…).
EOF
    exit 0
    ;;
  *)
    echo "Service inconnu: ${SERVICE} (api|ws|all)" >&2
    exit 1
    ;;
esac

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

run_cmd_optional() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] $*"
  else
    "$@" || true
  fi
}

print_disk_usage() {
  echo ""
  echo "--- Espace disque (${1}) ---"
  df -h / 2>/dev/null | awk 'NR==1 || NR==2 { print }'
  if [[ -d /var/lib/docker ]]; then
    df -h /var/lib/docker 2>/dev/null | awk 'NR==2 { print "docker:", $0 }' || true
  fi
  if command -v docker >/dev/null 2>&1; then
    docker system df 2>/dev/null | sed 's/^/docker: /' || true
  fi
}

echo "== Nettoyage disque post-déploiement (${SERVICE}) =="
print_disk_usage "avant"

echo ""
echo "→ Fichiers temporaires deploy (/tmp)..."
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "[dry-run] find /tmp -maxdepth 1 \\( -name 'api-env-tried.*' -o -name 'ws-env-tried.*' \\) -delete"
  echo "[dry-run] find /tmp -maxdepth 1 -type f -name 'africa-meals-*.tar' -mtime +0 -delete"
else
  find /tmp -maxdepth 1 \( -name 'api-env-tried.*' -o -name 'ws-env-tried.*' \) -delete 2>/dev/null || true
  find /tmp -maxdepth 1 -type f -name 'africa-meals-*.tar' -mtime +0 -delete 2>/dev/null || true
fi

if command -v docker >/dev/null 2>&1; then
  echo ""
  echo "→ Docker : cache de build (keep-storage=${KEEP_BUILD_CACHE_GB}GB)..."
  if docker builder prune --help 2>/dev/null | grep -q keep-storage; then
    run_cmd_optional docker builder prune -f --keep-storage "${KEEP_BUILD_CACHE_GB}GB"
  else
    run_cmd_optional docker builder prune -f
  fi

  echo "→ Docker : images dangling..."
  run_cmd_optional docker image prune -f

  if [[ "${SERVICE}" == "api" || "${SERVICE}" == "all" ]]; then
    echo "→ Docker : anciennes images africa-meals/api (<none>)..."
    run_cmd_optional docker images --filter "reference=africa-meals/api" --filter "dangling=true" -q \
      | xargs -r docker rmi -f 2>/dev/null
  fi
  if [[ "${SERVICE}" == "ws" || "${SERVICE}" == "all" ]]; then
    echo "→ Docker : anciennes images africa-meals/ws (<none>)..."
    run_cmd_optional docker images --filter "reference=africa-meals/ws" --filter "dangling=true" -q \
      | xargs -r docker rmi -f 2>/dev/null
  fi
fi

if command -v k3s >/dev/null 2>&1; then
  echo ""
  echo "→ k3s : pods arrêtés..."
  run_cmd_optional k3s crictl rmp -a

  echo "→ k3s : images containerd inutilisées (crictl rmi --prune)..."
  run_cmd_optional k3s crictl rmi --prune

  if k3s ctr images --help 2>/dev/null | grep -q '\bprune\b'; then
    echo "→ k3s : contenu containerd non référencé..."
    run_cmd_optional k3s ctr -n k8s.io content prune
  fi
elif command -v crictl >/dev/null 2>&1 && [[ -S /run/k3s/containerd/containerd.sock ]]; then
  echo ""
  echo "→ containerd : pods arrêtés + images inutilisées..."
  run_cmd_optional crictl rmp -a
  run_cmd_optional crictl rmi --prune
fi

print_disk_usage "après"
echo ""
echo "Nettoyage post-déploiement terminé."
