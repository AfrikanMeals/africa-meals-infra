#!/usr/bin/env bash
# Vérifie Loki + Promtail + présence de streams (anti-régression logs Grafana).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

fail=0

log "=== Loki + Promtail ==="

# /ready peut renvoyer "Ingester not ready" sous flood ; /labels prouve que l’API vit.
loki_body="$(curl -sf --max-time 5 http://127.0.0.1:3100/ready 2>/dev/null || true)"
if echo "${loki_body}" | grep -qiE '^ready$|ready'; then
  log "OK  Loki :3100 ready"
elif curl -sf --max-time 5 http://127.0.0.1:3100/loki/api/v1/labels >/dev/null 2>&1; then
  warn "Loki /ready « ${loki_body:-empty} » mais API labels OK (souvent flood timestamps trop vieux)"
else
  warn "FAIL Loki :3100 — docker logs wise-eat-loki"
  docker logs wise-eat-loki --tail=20 2>&1 | sed 's/^/      /' || true
  fail=1
fi

if curl -sf --max-time 5 http://127.0.0.1:9080/ready 2>/dev/null | grep -qi ready; then
  log "OK  Promtail :9080 ready"
else
  warn "FAIL Promtail :9080 — docker logs wise-eat-promtail"
  docker logs wise-eat-promtail --tail=25 2>&1 | sed 's/^/      /' || true
  fail=1
fi

# Labels / streams après quelques secondes d’ingestion.
sleep 2
# API Loki label names
if curl -sf --max-time 8 "http://127.0.0.1:3100/loki/api/v1/labels" 2>/dev/null \
  | grep -qE '"job"|"status":"success"'; then
  log "OK  Loki API /labels"
else
  warn "FAIL Loki /labels — pas encore de données ou Loki KO"
  fail=1
fi

# Au moins un job attendu (docker ou kubernetes ou journal)
LABELS_JSON="$(curl -sf --max-time 8 "http://127.0.0.1:3100/loki/api/v1/label/job/values" 2>/dev/null || true)"
if echo "${LABELS_JSON}" | grep -qE 'docker|kubernetes|journal'; then
  log "OK  Streams job présents (docker/kubernetes/journal)"
  echo "${LABELS_JSON}" | head -c 400
  echo ""
else
  warn "FAIL aucun job docker|kubernetes|journal — attendre 30s ou logs promtail"
  fail=1
fi

# Grafana datasource file provisionné
if [[ -f "${MON_DIR}/grafana/provisioning/datasources/loki.yml" ]]; then
  log "OK  provisioning datasource loki.yml"
else
  warn "FAIL loki.yml provisioning absent"
  fail=1
fi

if [[ -f "${MON_DIR}/grafana/dashboards/Logs/wise-eat-logs.json" ]]; then
  log "OK  dashboard Logs/wise-eat-logs.json"
else
  warn "FAIL dashboard Logs absent"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
log "Stack Loki OK — Grafana folder Logs + Explore Loki"
