#!/usr/bin/env bash
# Recrée le namespace Kubernetes « wise-eat » (API + WS) SANS toucher aux données.
#
# Supprime uniquement les ressources k8s du namespace (Deployments, Pods, Secrets,
# ConfigMaps, Services, HPA, PDB…).
#
# NE TOUCHE PAS :
#   • MongoDB Docker (volumes / data rs0)
#   • Redis / Memcached / BullMQ (volumes Docker)
#   • Stunnel, EMQX, nginx, certificats Let's Encrypt
#   • Images containerd déjà importées (sauf si --rebuild)
#
# Usage (VPS) :
#   sudo /opt/wise-eat/k8s/scripts/recreate-wise-eat-namespace.sh
#   sudo WS_ENV=/opt/wise-eat-ws/.env API_ENV=/opt/wise-eat-api/.env.prod \
#     /opt/wise-eat/k8s/scripts/recreate-wise-eat-namespace.sh
#   sudo ./recreate-wise-eat-namespace.sh --yes --rebuild
#
# Options :
#   --yes       Pas de confirmation interactive
#   --rebuild   Rebuild + import images WS/API avant apply
#   --ws-only   Recréer uniquement africa-meals-ws
#   --api-only  Recréer uniquement africa-meals-api
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=ws-paths.sh
source "${SCRIPT_DIR}/ws-paths.sh"
# shellcheck source=api-paths.sh
source "${SCRIPT_DIR}/api-paths.sh"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
WS_ENV_FILE="${WS_ENV:-}"
API_ENV_FILE="${API_ENV:-}"
ASSUME_YES=false
DO_REBUILD=false
WS_ONLY=false
API_ONLY=false

for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=true ;;
    --rebuild) DO_REBUILD=true ;;
    --ws-only) WS_ONLY=true ;;
    --api-only) API_ONLY=true ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --*)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ "${WS_ONLY}" == "true" && "${API_ONLY}" == "true" ]]; then
  echo "Choisir --ws-only OU --api-only, pas les deux." >&2
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
elif command -v k3s >/dev/null 2>&1; then
  # Préférer le kubeconfig k3s si présent
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  fi
fi

resolve_ws_env() {
  if [[ -n "${WS_ENV_FILE}" && -f "${WS_ENV_FILE}" ]]; then
    printf '%s\n' "${WS_ENV_FILE}"
    return 0
  fi
  local candidate
  for candidate in \
    /opt/wise-eat-ws/.env \
    /opt/wise-eat-ws/.env.prod \
    "${INFRA_ROOT:-}/../africa-meals-ws/.env.prod"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if WS_ENV_FILE="$(ws_resolve_env_file '' 2>/dev/null)"; then
    printf '%s\n' "${WS_ENV_FILE}"
    return 0
  fi
  return 1
}

resolve_api_env() {
  if [[ -n "${API_ENV_FILE}" && -f "${API_ENV_FILE}" ]]; then
    printf '%s\n' "${API_ENV_FILE}"
    return 0
  fi
  local candidate
  for candidate in \
    /opt/wise-eat-api/.env.prod \
    /opt/wise-eat-api/.env \
    "${INFRA_ROOT:-}/../africa-meals-api/.env.prod"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if API_ENV_FILE="$(api_resolve_env_file '' 2>/dev/null)"; then
    printf '%s\n' "${API_ENV_FILE}"
    return 0
  fi
  return 1
}

echo "============================================================"
echo " Recréation namespace Kubernetes : ${NAMESPACE}"
echo "============================================================"
echo ""
echo "SUPPRIMÉ : Deployments / Pods / Secrets / ConfigMaps / Services / HPA / PDB"
echo "CONSERVÉ : MongoDB · Redis · Memcached · Stunnel · volumes Docker · certs LE"
echo ""

if [[ "${ASSUME_YES}" != "true" ]]; then
  read -r -p "Confirmer la suppression du namespace « ${NAMESPACE} » ? [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) ;;
    *)
      echo "Annulé."
      exit 0
      ;;
  esac
fi

echo ""
echo "== 1/5 Snapshot (avant delete) =="
"${KUBECTL[@]}" get all,cm,secret,hpa,pdb -n "${NAMESPACE}" 2>/dev/null || \
  echo "(namespace absent ou vide)"

echo ""
echo "== 2/5 Suppression namespace ${NAMESPACE} =="
if "${KUBECTL[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  "${KUBECTL[@]}" delete namespace "${NAMESPACE}" --wait=true --timeout=180s
  echo "Namespace ${NAMESPACE} supprimé."
else
  echo "Namespace ${NAMESPACE} déjà absent."
fi

# Attendre la disparition complète (finalizers)
for i in $(seq 1 60); do
  if ! "${KUBECTL[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    break
  fi
  echo "… attente disparition namespace (${i}/60)"
  sleep 2
done
if "${KUBECTL[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERREUR: namespace ${NAMESPACE} encore présent (finalizer bloqué)." >&2
  "${KUBECTL[@]}" get namespace "${NAMESPACE}" -o yaml | tail -40 >&2 || true
  exit 1
fi

echo ""
echo "== 3/5 Recréation namespace + Secrets =="
"${KUBECTL[@]}" create namespace "${NAMESPACE}"

DO_WS=true
DO_API=true
[[ "${API_ONLY}" == "true" ]] && DO_WS=false
[[ "${WS_ONLY}" == "true" ]] && DO_API=false

if [[ "${DO_WS}" == "true" ]]; then
  WS_ENV_RESOLVED="$(resolve_ws_env)" || {
    echo "Fichier .env WS introuvable. Ex. : WS_ENV=/opt/wise-eat-ws/.env $0" >&2
    exit 1
  }
  echo "WS env : ${WS_ENV_RESOLVED}"
  "${SCRIPT_DIR}/create-ws-secret.sh" "${WS_ENV_RESOLVED}"
fi

if [[ "${DO_API}" == "true" ]]; then
  API_ENV_RESOLVED="$(resolve_api_env)" || {
    echo "Fichier .env API introuvable. Ex. : API_ENV=/opt/wise-eat-api/.env.prod $0" >&2
    exit 1
  }
  echo "API env : ${API_ENV_RESOLVED}"
  "${SCRIPT_DIR}/create-api-secret.sh" "${API_ENV_RESOLVED}"
  # Secrets optionnels (ne pas faire échouer si absents)
  local_firebase="${FIREBASE_SA:-/opt/wise-eat-api/accounts.json}"
  local_recaptcha="${RECAPTCHA_SA:-/opt/wise-eat-api/recaptcha-accounts.json}"
  if [[ -f "${local_firebase}" ]]; then
    "${SCRIPT_DIR}/create-api-firebase-secret.sh" "${local_firebase}" || \
      echo "WARN: secret Firebase API non créé (ignoré)"
  else
    echo "accounts.json absent (${local_firebase}) — Firebase optionnel ignoré"
  fi
  if [[ -f "${local_recaptcha}" ]]; then
    "${SCRIPT_DIR}/create-api-recaptcha-secret.sh" "${local_recaptcha}" || \
      echo "WARN: secret reCAPTCHA API non créé (ignoré)"
  else
    echo "recaptcha-accounts.json absent (${local_recaptcha}) — optionnel ignoré"
  fi
fi

echo ""
echo "== 4/5 Apply manifests + hostAliases =="
DEPLOY_EXTRA=()
[[ "${DO_REBUILD}" == "true" ]] && DEPLOY_EXTRA+=(--build)

if [[ "${DO_WS}" == "true" ]]; then
  "${SCRIPT_DIR}/deploy-ws.sh" --verify --skip-cleanup "${DEPLOY_EXTRA[@]+"${DEPLOY_EXTRA[@]}"}" || {
    echo "WARN: deploy-ws.sh a échoué (rollout) — hostAliases / logs à vérifier" >&2
  }
fi

if [[ "${DO_API}" == "true" ]]; then
  "${SCRIPT_DIR}/deploy-api.sh" --verify --skip-cleanup "${DEPLOY_EXTRA[@]+"${DEPLOY_EXTRA[@]}"}" || {
    echo "WARN: deploy-api.sh a échoué (rollout) — hostAliases / logs à vérifier" >&2
  }
fi

# Garantir host.k3s.internal → cni0 (pas l’IP publique)
if [[ -x "${SCRIPT_DIR}/ensure-k3s-host-gateway.sh" ]]; then
  echo "hostAliases host.k3s.internal…"
  K3S_HOST_GATEWAY_IP="${K3S_HOST_GATEWAY_IP:-}" "${SCRIPT_DIR}/ensure-k3s-host-gateway.sh" || true
fi

echo ""
echo "== 5/5 État final =="
"${KUBECTL[@]}" get pods,deploy,hpa,svc -n "${NAMESPACE}" -o wide || true
echo ""
echo "Données Mongo/Redis/Memcached : intactes (hors namespace k8s)."
echo ""
echo "Vérifs :"
echo "  kubectl -n ${NAMESPACE} exec deploy/africa-meals-ws -- getent hosts host.k3s.internal"
echo "  kubectl -n ${NAMESPACE} logs deploy/africa-meals-ws --tail=40"
echo "  curl -sS http://127.0.0.1:30800/api/health ; curl -sS http://127.0.0.1:30900/api/health"
echo ""
echo "Note : pods → host.k3s.internal (cni0) → Mongo/Redis/Memcached plaintext."
echo "       Stunnel (:27018/:6381…) = accès distant uniquement."
echo "Si ENOTFOUND host.k3s.internal : hostAliases manquants — git pull + redeploy."
echo "Si ECONNREFUSED : republier Docker sur cni0 :"
echo "  cd /opt/wise-eat/mongodb && sudo K3S_CNI_GATEWAY=10.42.0.1 docker compose up -d"
echo "  cd /opt/wise-eat/redis && sudo K3S_CNI_GATEWAY=10.42.0.1 docker compose up -d"
echo "  cd /opt/wise-eat/memcached && sudo K3S_CNI_GATEWAY=10.42.0.1 docker compose up -d"
echo "  sudo /opt/wise-eat/scripts/ufw-allow-k3s-pods.sh"
