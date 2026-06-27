#!/usr/bin/env bash
# Déploie africa-meals-ws en production k8s (3 pods, failover, restart automatique).
#
# Prérequis VPS :
#   - k3s (install-k3s.sh)
#   - infra Docker (Redis/Mongo/EMQX Stunnel) sur le même hôte
#   - wise-eat-ws/.env ou africa-meals-ws/.env pour les secrets
#
# Usage (VPS — dépôts séparés sous /opt) :
#   sudo ./deploy-ws-production.sh /opt/wise-eat-ws/.env
#   sudo ./deploy-ws-production.sh                    # auto-détection .env
#
# Usage (monorepo local) :
#   sudo ./deploy-ws-production.sh africa-meals-ws/.env
#   sudo ./deploy-ws-production.sh africa-meals-ws/.env --skip-k3s
#   sudo ./deploy-ws-production.sh africa-meals-ws/.env --skip-nginx
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ws-paths.sh
source "${SCRIPT_DIR}/ws-paths.sh"

ENV_ARG="${1:-}"
SKIP_K3S=false
SKIP_NGINX=false

if [[ "${ENV_ARG}" == --* ]]; then
  ENV_ARG=""
else
  shift || true
fi

for arg in "$@"; do
  case "${arg}" in
    --skip-k3s) SKIP_K3S=true ;;
    --skip-nginx) SKIP_NGINX=true ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [<chemin/.env>] [--skip-k3s] [--skip-nginx]

Production k8s — 3 pods africa-meals-ws (PM2 réservé au dev local).

VPS (/opt) :
  sudo $0 /opt/wise-eat-ws/.env
  sudo $0    # auto : /opt/wise-eat-ws/.env ou africa-meals-ws/.env

Monorepo :
  sudo $0 africa-meals-ws/.env
EOF
      exit 0
      ;;
    *)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

RESOLVED_ENV=""
if RESOLVED_ENV="$(ws_resolve_env_file "${ENV_ARG}" 2>/tmp/ws-env-tried.$$)"; then
  ENV_FILE="${RESOLVED_ENV}"
else
  echo "Usage: sudo $0 [<chemin/.env>] [--skip-k3s] [--skip-nginx]" >&2
  echo "" >&2
  ws_env_file_usage_hint >&2
  if [[ -s /tmp/ws-env-tried.$$ ]]; then
    echo "Chemins testés :" >&2
    tr ' ' '\n' < /tmp/ws-env-tried.$$ | sed 's/^/  - /' >&2
  fi
  rm -f /tmp/ws-env-tried.$$
  exit 1
fi
rm -f /tmp/ws-env-tried.$$

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0 ${ENV_FILE}" >&2
  exit 1
fi

echo "== Fichier .env : ${ENV_FILE} =="

echo "== 1/5 k3s =="
if [[ "${SKIP_K3S}" == "false" ]] && ! command -v k3s >/dev/null 2>&1; then
  "${SCRIPT_DIR}/install-k3s.sh"
fi

echo "== 2/5 Build + import image =="
"${SCRIPT_DIR}/build-ws-image.sh"

echo "== 3/5 Secret (host.k3s.internal / TLS SNI via ConfigMap) =="
"${SCRIPT_DIR}/create-ws-secret.sh" "${ENV_FILE}"

echo "== 4/5 Déploiement 3 pods =="
"${SCRIPT_DIR}/deploy-ws.sh" --verify

if [[ "${SKIP_NGINX}" == "false" ]]; then
  echo "== 5/5 nginx → NodePort 30800 =="
  "${SCRIPT_DIR}/patch-nginx-ws-backend.sh"
else
  echo "== 5/5 nginx ignoré (--skip-nginx) =="
fi

cat <<EOF

Production WS déployée (k8s, 3 pods).
  Santé   : curl -s http://127.0.0.1:30800/api/health
  Pods    : sudo k3s kubectl get pods -n wise-eat -o wide
  Events  : sudo k3s kubectl get events -n wise-eat --sort-by=.lastTimestamp | tail -20
  Logs    : sudo k3s kubectl logs -n wise-eat -l app.kubernetes.io/name=africa-meals-ws -f --tail=100

PM2 : réservé au dev — ne pas lancer africa-meals-ws en prod sur le VPS.
EOF
