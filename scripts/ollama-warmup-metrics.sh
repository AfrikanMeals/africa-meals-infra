#!/usr/bin/env bash
# Charge llama3.2:3b en VRAM + une requête via le proxy pour remplir Grafana Ollama (#25086).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODEL="${OLLAMA_WARMUP_MODEL:-llama3.2:3b}"
DIRECT_URL="${OLLAMA_DIRECT_URL:-http://127.0.0.1:11434}"
PROXY_URL="${OLLAMA_PROXY_URL:-http://127.0.0.1:9401}"

payload="$(printf '{"model":"%s","prompt":"ping","stream":false}' "${MODEL}")"

log "Warmup Ollama — modèle ${MODEL} (VRAM + métriques proxy)"

curl -sf "${DIRECT_URL}/api/generate" -H 'Content-Type: application/json' -d "${payload}" >/dev/null \
  || die "Échec generate direct — Ollama injoignable sur ${DIRECT_URL}"

if curl -sf "${PROXY_URL}/api/generate" -H 'Content-Type: application/json' -d "${payload}" >/dev/null; then
  log "Requête proxy OK (${PROXY_URL}) — TPS/latences disponibles dans Grafana"
else
  warn "Proxy ${PROXY_URL} injoignable — lancer : sudo ./install.sh monitoring"
fi

sleep 3
if curl -sf http://127.0.0.1:9400/metrics | grep -q '^ollama_model_loaded'; then
  log "Métriques ollama_model_* présentes sur :9400"
else
  warn "Pas encore de ollama_model_loaded — réessayer dans 15s (poll_interval)"
fi

log "Grafana : Wise Eat — Ollama LLM Inference"
