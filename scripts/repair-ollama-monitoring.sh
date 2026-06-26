#!/usr/bin/env bash
# Recréer Ollama + ollama-exporter pour Grafana (#25086).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component ollama
cd "${OLLAMA_DIR}"

if [[ ! -f .env.ollama ]]; then
  die "Ollama non installé — sudo ./install.sh ollama"
fi

set -a && source .env.ollama && set +a

log "Recréation conteneur Ollama…"
docker compose --env-file .env.ollama up -d --force-recreate

wait_for_ollama_api 90 || die "Ollama API injoignable après recréation"

ensure_ollama_on_wise_eat_infra || true

if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-ollama-exporter'; then
  log "Redémarrage ollama-exporter…"
  docker restart wise-eat-ollama-exporter >/dev/null
  sleep 5
else
  warn "ollama-exporter absent — sudo ./install.sh monitoring"
fi

verify_ollama_exporter_metrics 30 || true

echo ""
log "Vérification manuelle :"
echo "  curl -s http://127.0.0.1:9400/metrics | grep '^ollama_up '"
echo "  curl -sG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=ollama_up{job=\"ollama\"}'"
echo ""
log "Grafana : Wise Eat — Ollama LLM Inference (#25086)"
