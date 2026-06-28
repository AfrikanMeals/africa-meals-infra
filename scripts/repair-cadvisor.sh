#!/usr/bin/env bash
# Recréer cAdvisor (cgroup v2 + Docker 29 overlayfs) et valider métriques conteneur Grafana.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation cAdvisor (Wise Eat — Docker Monitoring) ==="

sync_component monitoring

storage_driver="$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')"
log "Storage Driver Docker : ${storage_driver:-inconnu}"
if [[ "${storage_driver}" == "overlayfs" ]]; then
  log "Docker 29 overlayfs — cAdvisor v0.60+ + --disable_metrics=disk"
fi

if ensure_cadvisor; then
  count="$(curl -sf http://127.0.0.1:8088/metrics \
    | grep '^container_cpu_usage_seconds_total' | grep -v 'id="/"' | wc -l | tr -d ' ')"
  log "cAdvisor OK — ${count} série(s) container_cpu (hors racine)"
  log "Grafana : Core System → Wise Eat — Docker Monitoring"
  exit 0
fi

warn "cAdvisor KO — vérifier : curl -s http://127.0.0.1:8088/metrics | grep container_cpu | head"
exit 1
