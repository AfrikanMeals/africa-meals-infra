#!/usr/bin/env bash
# Déploiement Headlamp + nginx public k8s.wise-eat.com
#
# Prérequis DNS : A/AAAA k8s.wise-eat.com → VPS (DNS only, pas proxy orange CF)
#
# Usage :
#   sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./deploy-k8s-dashboard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_HEADLAMP=false
SKIP_TLS=false

for arg in "$@"; do
  case "${arg}" in
    --skip-headlamp) SKIP_HEADLAMP=true ;;
    --skip-tls) SKIP_TLS=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo deploy-k8s-dashboard.sh [options]

Variables :
  STUNNEL_TLS_EMAIL                   Let's Encrypt

Options :
  --skip-headlamp   nginx seulement
  --skip-tls        HTTP seulement (ACME webroot)
EOF
      exit 0
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

echo "== 1/3 Headlamp (UI Kubernetes) =="
if [[ "${SKIP_HEADLAMP}" == "false" ]]; then
  "${SCRIPT_DIR}/install-headlamp.sh"
fi

echo ""
echo "== 2/3 nginx k8s.wise-eat.com =="
if [[ "${SKIP_TLS}" == "false" && -n "${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}" ]]; then
  "${SCRIPT_DIR}/enable-k8s-nginx-ssl.sh"
else
  "${SCRIPT_DIR}/install-k8s-nginx.sh"
fi

echo ""
echo "== 3/3 Token connexion Headlamp =="
"${SCRIPT_DIR}/create-headlamp-admin-token.sh" 8760h | tail -5

cat <<'EOF'

=== Headlamp déployé ===

URL     : https://k8s.wise-eat.com/
Auth    : token ServiceAccount headlamp-admin (pas de mot de passe nginx)

Regénérer token :
  sudo k8s/scripts/create-headlamp-admin-token.sh
EOF
