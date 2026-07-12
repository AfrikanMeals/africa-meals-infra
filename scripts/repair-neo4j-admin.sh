#!/usr/bin/env bash
# Répare Neo4j Browser + nginx (db-graph.wise-eat.com 502) + retire DbGate legacy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component neo4j
cd "${NEO4J_DIR}"

[[ -f .env.neo4j ]] || die ".env.neo4j absent — sudo ./install.sh neo4j"

source_dotenv .env.neo4j
NEO4J_HTTP_PORT="${NEO4J_HTTP_PORT:-7474}"

log "=== Réparation Neo4j Browser (db-graph.wise-eat.com) ==="

docker rm -f wise-eat-neo4j-dbgate 2>/dev/null || true

if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-neo4j'; then
  bash "${SCRIPT_DIR}/install-neo4j.sh"
else
  docker compose --env-file .env.neo4j up -d --force-recreate neo4j
fi

log "Attente Neo4j Browser HTTP (max 90s)…"
ok=0
for _ in $(seq 1 45); do
  if curl -sf --max-time 3 "http://127.0.0.1:${NEO4J_HTTP_PORT}/" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "${ok}" -ne 1 ]]; then
  warn "Neo4j HTTP injoignable — logs :"
  docker logs --tail=40 wise-eat-neo4j 2>&1 | sed 's/^/[wise-eat]   /'
  die "Échec — vérifier wise-eat-neo4j"
fi

log "OK  Neo4j Browser local :${NEO4J_HTTP_PORT}"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-neo4j-admin.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-neo4j-admin-ssl.sh" 2>/dev/null || true
  nginx_test_and_reload || true
fi

log "Terminé — https://${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}"
log "  Connect URI Browser : bolt+s://${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}:${NEO4J_BOLT_TLS_PORT:-7688}"
