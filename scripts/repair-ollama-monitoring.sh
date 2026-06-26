#!/usr/bin/env bash
# Recréer Ollama (labels monitoring) + redémarrer cAdvisor pour Grafana.
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

log "Recréation conteneur Ollama (labels com.wise-eat.service=ollama)…"
docker compose --env-file .env.ollama up -d --force-recreate

wait_for_ollama_api 90 || die "Ollama API injoignable après recréation"

refresh_cadvisor_if_present
verify_cadvisor_ollama_metrics 20 || true

echo ""
log "Vérification manuelle :"
echo "  curl -s http://127.0.0.1:8088/metrics | grep -E 'wise-eat-ollama|com_wise_eat_service' | head"
echo "  curl -s http://127.0.0.1:9090/api/v1/query?query=container_memory_rss{container_label_com_wise_eat_service=\"ollama\"}"
echo ""
log "Grafana : Wise Eat — Ollama · Wise Eat — Ollama API Health"
