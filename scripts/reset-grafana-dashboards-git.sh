#!/usr/bin/env bash
# Réinitialise les dashboards Grafana générés localement (repair / fetch-grafana-dashboard)
# pour permettre un git pull sans conflit sur le VPS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="${WISE_EAT_ROOT:-${INFRA_ROOT}}"
DASH_DIR="${ROOT}/monitoring/grafana/dashboards"

if ! git -C "${ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
  die "Pas un dépôt git : ${ROOT}"
fi

log "Réinitialisation dashboards Grafana (fichiers générés par install/repair)…"
git -C "${ROOT}" checkout -- monitoring/grafana/dashboards/ 2>/dev/null || true
git -C "${ROOT}" clean -fd monitoring/grafana/dashboards/ 2>/dev/null || true

if git -C "${ROOT}" status --porcelain monitoring/grafana/dashboards/ | grep -q .; then
  warn "Modifications restantes dans monitoring/grafana/dashboards/ :"
  git -C "${ROOT}" status --short monitoring/grafana/dashboards/
else
  log "OK — git pull possible"
fi
