#!/usr/bin/env bash
# Déploiement production complet africa-meals-ws (k8s + nginx + monitoring).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=ws-paths.sh
source "${SCRIPT_DIR}/ws-paths.sh"

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
Usage: sudo deploy-ws-production.sh [<.env>] [options]

Options:
  --skip-k3s          k3s déjà installé
  --skip-nginx        nginx ws.wise-eat.com déjà configuré
  --skip-monitoring   kube-state-metrics + Prometheus targets
  --skip-tls          ne pas émettre le certificat LE ws.wise-eat.com

VPS (/opt) :
  sudo deploy-ws-production.sh /opt/wise-eat-ws/.env.prod
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
if RESOLVED_ENV="$(ws_resolve_env_file "${ENV_ARG}" 2>/tmp/ws-env-tried.$$)"; then
  ENV_FILE="${RESOLVED_ENV}"
else
  ws_env_file_usage_hint >&2
  rm -f /tmp/ws-env-tried.$$
  exit 1
fi
rm -f /tmp/ws-env-tried.$$

echo "== .env : ${ENV_FILE} =="
if grep -qE '^MONGODB_URI=mongodb\+srv://' "${ENV_FILE}" 2>/dev/null; then
  echo "ATTENTION: .env Atlas détecté — en prod VPS préférez /opt/wise-eat-ws/.env.prod" >&2
fi

echo "== 1/7 k3s (swap VPS + kubelet) =="
if [[ "${SKIP_K3S}" == "false" ]]; then
  "${SCRIPT_DIR}/install-k3s.sh"
fi

echo "== 2/7 kube-state-metrics =="
if [[ "${SKIP_MONITORING}" == "false" ]]; then
  "${SCRIPT_DIR}/install-kube-state-metrics.sh"
fi

echo "== 3/7 Build image WS =="
"${SCRIPT_DIR}/build-ws-image.sh"

echo "== 4/7 Secret Kubernetes =="
"${SCRIPT_DIR}/create-ws-secret.sh" "${ENV_FILE}"

echo "== 5/7 Déploiement WS + HPA (3–5 pods, 512 Mi/pod, restart Always) =="
"${SCRIPT_DIR}/deploy-ws.sh" --verify

if [[ "${SKIP_MONITORING}" == "false" ]]; then
  echo "== 6/7 Prometheus (node_exporter + cibles WS) =="
  if [[ -x "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" ]]; then
    "${INFRA_ROOT}/scripts/repair-prometheus-host-targets.sh" || true
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
    "${SCRIPT_DIR}/recreate-prometheus-host.sh" || true
  fi
  "${SCRIPT_DIR}/sync-prometheus-ws-targets.sh" || true
  if [[ -x "${SCRIPT_DIR}/install-ws-prometheus-cron.sh" ]]; then
    "${SCRIPT_DIR}/install-ws-prometheus-cron.sh" || true
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-grafana'; then
    docker restart wise-eat-grafana >/dev/null 2>&1 || true
  fi
fi

if [[ "${SKIP_NGINX}" == "false" ]]; then
  echo "== 7/7 nginx ws.wise-eat.com =="
  if [[ "${SKIP_TLS}" == "false" && ! -f /etc/letsencrypt/live/ws.wise-eat.com/fullchain.pem ]]; then
    if [[ -z "${STUNNEL_TLS_EMAIL:-${CERTBOT_EMAIL:-}}" ]]; then
      echo "Certificat absent — HTTP seul. Pour HTTPS :" >&2
      echo "  sudo STUNNEL_TLS_EMAIL=you@wise-eat.com ${SCRIPT_DIR}/enable-ws-nginx-ssl.sh" >&2
      "${SCRIPT_DIR}/install-ws-nginx.sh"
    else
      "${SCRIPT_DIR}/enable-ws-nginx-ssl.sh"
    fi
  else
    "${SCRIPT_DIR}/install-ws-nginx.sh"
  fi
else
  echo "== 7/7 nginx ignoré (--skip-nginx) =="
fi

cat <<'EOF'

=== Déploiement terminé ===

Public :
  https://ws.wise-eat.com/api/health
  wss://ws.wise-eat.com/stomp          (STOMP)
  wss://ws.wise-eat.com/socket.io/     (Socket.IO)

Interne VPS :
  curl -s http://127.0.0.1:30800/api/health
  sudo k3s kubectl get pods -n wise-eat -o wide
  sudo k3s kubectl get hpa africa-meals-ws -n wise-eat

Grafana :
  Dossier « Servers » → dashboard « Africa Meals WS (k8s) »
  (redémarrer Grafana si dashboard absent : docker restart wise-eat-grafana)

PM2 : réservé au dev local — ne pas lancer africa-meals-ws en prod sur le VPS.
EOF
