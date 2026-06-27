#!/usr/bin/env bash
# Déploie africa-meals-ws en production k8s (3 pods, failover, restart automatique).
#
# Prérequis VPS :
#   - k3s (install-k3s.sh)
#   - infra Docker (Redis/Mongo/EMQX Stunnel) sur le même hôte
#   - africa-meals-ws/.env pour les secrets
#
# Usage :
#   sudo ./deploy-ws-production.sh africa-meals-ws/.env
#   sudo ./deploy-ws-production.sh africa-meals-ws/.env --skip-k3s
#   sudo ./deploy-ws-production.sh africa-meals-ws/.env --skip-nginx
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-}"
SKIP_K3S=false
SKIP_NGINX=false

shift || true
for arg in "$@"; do
  case "${arg}" in
    --skip-k3s) SKIP_K3S=true ;;
    --skip-nginx) SKIP_NGINX=true ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 <africa-meals-ws/.env> [--skip-k3s] [--skip-nginx]

Production k8s — 3 pods africa-meals-ws (PM2 réservé au dev local).
EOF
      exit 0
      ;;
    *)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
  echo "Usage: sudo $0 <africa-meals-ws/.env>" >&2
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0 ${ENV_FILE}" >&2
  exit 1
fi

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
