#!/usr/bin/env bash
# Déploiement production complet africa-meals-api (k8s + nginx + monitoring).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=api-paths.sh
source "${SCRIPT_DIR}/api-paths.sh"

ENV_ARG="${1:-}"
SKIP_K3S=false
SKIP_NGINX=false
SKIP_MONITORING=false
SKIP_TLS=false

if [[ "${ENV_ARG}" == --* ]]; then
  ENV_ARG=""
else
  shift || true
fi

for arg in "$@"; do
  case "${arg}" in
    --skip-k3s) SKIP_K3S=true ;;
    --skip-nginx) SKIP_NGINX=true ;;
    --skip-monitoring) SKIP_MONITORING=true ;;
    --skip-tls) SKIP_TLS=true ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo deploy-api-production.sh [<.env.prod>] [options]

Options:
  --skip-k3s          k3s déjà installé
  --skip-nginx        nginx api.wise-eat.com déjà configuré
  --skip-monitoring   kube-state-metrics + Prometheus targets
  --skip-tls          ne pas émettre le certificat LE api.wise-eat.com

VPS (/opt) :
  sudo deploy-api-production.sh /opt/wise-eat-api/.env.prod
EOF
      exit 0
      ;;
    *)
      echo "Option inconnue: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

RESOLVED_ENV=""
if RESOLVED_ENV="$(api_resolve_env_file "${ENV_ARG}" 2>/tmp/api-env-tried.$$)"; then
  ENV_FILE="${RESOLVED_ENV}"
else
  api_env_file_usage_hint >&2
  rm -f /tmp/api-env-tried.$$
  exit 1
fi
rm -f /tmp/api-env-tried.$$

API_DIR="$(dirname "${ENV_FILE}")"
FIREBASE_SA="${API_DIR}/accounts.json"
RECAPTCHA_SA="${API_DIR}/recaptcha-accounts.json"

echo "== .env : ${ENV_FILE} =="
if grep -qE '^MONGODB_URI=mongodb\+srv://' "${ENV_FILE}" 2>/dev/null; then
  echo "ATTENTION: .env Atlas détecté — en prod VPS préférez Stunnel host.k3s.internal:27018" >&2
fi

echo "== 1/8 k3s (swap VPS + kubelet) =="
if [[ "${SKIP_K3S}" == "false" ]]; then
  "${SCRIPT_DIR}/install-k3s.sh"
fi

echo "== 2/8 kube-state-metrics =="
if [[ "${SKIP_MONITORING}" == "false" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh"
fi

echo "== 3/8 Build image API =="
"${SCRIPT_DIR}/build-api-image.sh"

echo "== 4/8 Secrets Kubernetes =="
"${SCRIPT_DIR}/create-api-secret.sh" "${ENV_FILE}"
if [[ -f "${FIREBASE_SA}" ]]; then
  "${SCRIPT_DIR}/create-api-firebase-secret.sh" "${FIREBASE_SA}"
else
  echo "accounts.json absent (${FIREBASE_SA}) — montage Firebase optionnel ignoré"
fi
if [[ -f "${RECAPTCHA_SA}" ]]; then
  "${SCRIPT_DIR}/create-api-recaptcha-secret.sh" "${RECAPTCHA_SA}"
else
  echo "recaptcha-accounts.json absent (${RECAPTCHA_SA}) — SA reCAPTCHA wise-eat-com optionnel ignoré"
fi

echo "== 5/8 Déploiement 5 pods (512 Mi × 5 ≈ 2,5 Gi + restart Always) =="
"${SCRIPT_DIR}/deploy-api.sh" --verify

echo "== 6/8 Mise à jour WS → API interne k8s =="
KUBECTL=(kubectl)
command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1 && KUBECTL=(sudo k3s kubectl)
if "${KUBECTL[@]}" get configmap africa-meals-ws -n wise-eat >/dev/null 2>&1; then
  "${KUBECTL[@]}" patch configmap africa-meals-ws -n wise-eat --type merge \
    -p '{"data":{"AFRICA_MEALS_API_INTERNAL_BASE_URL":"http://africa-meals-api.wise-eat.svc.cluster.local:9000/api"}}' || true
  "${KUBECTL[@]}" rollout restart deployment/africa-meals-ws -n wise-eat 2>/dev/null || true
fi

if [[ "${SKIP_MONITORING}" == "false" ]]; then
  echo "== 7/8 Prometheus (node_exporter + cibles API) =="
  # recreate-prometheus-host seul casse le scrape node si prometheus.yml n'est pas à jour (127.0.0.1:9100)
  if [[ -x "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" ]]; then
    "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" || true
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
    "${SCRIPT_DIR}/recreate-prometheus-host.sh" || true
  fi
  "${SCRIPT_DIR}/sync-prometheus-api-targets.sh" || true
  "${SCRIPT_DIR}/sync-prometheus-ws-targets.sh" || true
  if [[ -x "${SCRIPT_DIR}/install-api-prometheus-cron.sh" ]]; then
    "${SCRIPT_DIR}/install-api-prometheus-cron.sh" || true
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-grafana'; then
    docker restart wise-eat-grafana >/dev/null 2>&1 || true
  fi
fi

if [[ "${SKIP_NGINX}" == "false" ]]; then
  echo "== 8/8 nginx api.wise-eat.com =="
  if [[ "${SKIP_TLS}" == "false" && ! -f /etc/letsencrypt/live/api.wise-eat.com/fullchain.pem ]]; then
    if [[ -z "${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}" ]]; then
      echo "Certificat absent — HTTP seul. Pour HTTPS :" >&2
      echo "  sudo STUNNEL_TLS_EMAIL=you@wise-eat.com ${SCRIPT_DIR}/enable-api-nginx-ssl.sh" >&2
      "${SCRIPT_DIR}/install-api-nginx.sh"
    else
      "${SCRIPT_DIR}/enable-api-nginx-ssl.sh"
    fi
  else
    "${SCRIPT_DIR}/install-api-nginx.sh"
  fi
else
  echo "== 8/8 nginx ignoré (--skip-nginx) =="
fi

cat <<'EOF'

=== Déploiement API terminé ===

Public :
  https://api.wise-eat.com/api/health
  https://api.wise-eat.com/api/docs

Interne VPS :
  curl -s http://127.0.0.1:30900/api/health
  sudo k3s kubectl get pods -n wise-eat -l app.kubernetes.io/name=africa-meals-api -o wide

Headlamp (k8s.wise-eat.com) :
  namespace wise-eat → deployments africa-meals-api + africa-meals-ws

Grafana :
  Dossier « Servers » → dashboard « Africa Meals API (k8s) »
  (docker restart wise-eat-grafana si dashboard absent)

PM2 : ne pas lancer africa-meals-api en prod sur le VPS — k3s uniquement.
EOF
