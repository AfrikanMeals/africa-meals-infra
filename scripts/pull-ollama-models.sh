#!/usr/bin/env bash
# Télécharge les modèles Ollama configurés dans .env.ollama (OLLAMA_MODELS).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OLLAMA_DIR="${OLLAMA_DIR:-${WISE_EAT_ROOT}/ollama}"
[[ -f "${OLLAMA_DIR}/.env.ollama" ]] || die ".env.ollama absent — lancer install-ollama d'abord"
set -a && source "${OLLAMA_DIR}/.env.ollama" && set +a

MODELS_RAW="${OLLAMA_MODELS:-nomic-embed-text,llama3.2:3b}"
IFS=',' read -ra MODELS <<< "${MODELS_RAW}"

command -v docker >/dev/null 2>&1 || die "Docker requis"

if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-ollama'; then
  die "Conteneur wise-eat-ollama absent — sudo ./install.sh ollama"
fi

for model in "${MODELS[@]}"; do
  model="$(echo "${model}" | xargs)"
  [[ -n "${model}" ]] || continue
  log "Pull modèle Ollama : ${model} (peut prendre plusieurs minutes)…"
  docker exec wise-eat-ollama ollama pull "${model}"
done

log "Modèles installés :"
docker exec wise-eat-ollama ollama list
