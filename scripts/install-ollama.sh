#!/usr/bin/env bash
# Ollama Docker — nomic-embed-text + llama3.2:3b (Wise Eat AI stack).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component ollama
cd "${OLLAMA_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.ollama ]]; then
  cp .env.example .env.ollama
  OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  sed -i "s|^OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD=.*|OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD=${OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD}|" .env.ollama
  chmod 600 .env.ollama
  log "Mot de passe basic auth Ollama généré → ${OLLAMA_DIR}/.env.ollama"
fi

set -a && source .env.ollama && set +a

OLLAMA_DATA_DIR="${OLLAMA_DATA_DIR:-/var/lib/wise-eat/ollama}"
mkdir -p "${OLLAMA_DATA_DIR}"
chmod 755 "${OLLAMA_DATA_DIR}"

log "Démarrage Ollama Docker (modèles : ${OLLAMA_DATA_DIR})"
docker compose --env-file .env.ollama pull
docker compose --env-file .env.ollama up -d

if ! wait_for_ollama_api 90; then
  die "Ollama ne répond pas sur :${OLLAMA_PORT:-11434} — voir docker logs wise-eat-ollama"
fi

ensure_ollama_on_wise_eat_infra || true

refresh_cadvisor_if_present

if [[ "${OLLAMA_PULL_MODELS:-1}" == "1" ]]; then
  bash "${SCRIPT_DIR}/pull-ollama-models.sh"
fi

verify_cadvisor_ollama_metrics || true

docker compose --env-file .env.ollama ps

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-ollama-gateway.sh" 2>/dev/null || \
    warn "nginx Ollama gateway non configuré — lancer : sudo STUNNEL_TLS_EMAIL=... ./install.sh ollama-gateway"
fi

GATEWAY_DOMAIN="${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}"
GATEWAY_USER="${OLLAMA_GATEWAY_BASIC_AUTH_USER:-ollama}"

cat <<EOF

Ollama prêt (Wise Eat AI).

API locale (sans auth — africa-meals-api sur le VPS) :
  OLLAMA_BASE_URL=http://127.0.0.1:${OLLAMA_PORT:-11434}

API publique (IPv4 + IPv6 via nginx, basic auth) :
  OLLAMA_BASE_URL=https://${GATEWAY_DOMAIN}
  Basic auth : ${GATEWAY_USER} / voir ${OLLAMA_DIR}/.env.ollama

Modèles :
  ollama list  (dans le conteneur wise-eat-ollama)

Grafana : dashboard « Wise Eat — Ollama » (cAdvisor + mémoire hôte)
Certificat TLS : sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh ollama-gateway

EOF
