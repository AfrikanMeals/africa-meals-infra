#!/usr/bin/env bash
# Répare DbGate Neo4j + nginx (db-graph.wise-eat.com 502).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component neo4j
cd "${NEO4J_DIR}"

[[ -f .env.neo4j ]] || die ".env.neo4j absent — sudo ./install.sh neo4j"

source_dotenv .env.neo4j
NEO4J_DBGATE_PORT="${NEO4J_DBGATE_PORT:-8082}"

log "=== Réparation DbGate Neo4j (db-graph.wise-eat.com) ==="

if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-neo4j'; then
  bash "${SCRIPT_DIR}/install-neo4j.sh"
fi

mkdir -p "${NEO4J_DBGATE_DATA:-./data-dbgate}"

log "Recréation DbGate Neo4j"
docker compose --env-file .env.neo4j up -d --force-recreate dbgate

log "Attente DbGate (max 90s)…"
ok=0
for _ in $(seq 1 45); do
  code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NEO4J_DBGATE_PORT}/" 2>/dev/null || echo 000)"
  if [[ "${code}" =~ ^(200|302|401)$ ]]; then
    ok=1
    break
  fi
  if docker logs wise-eat-neo4j-dbgate 2>&1 | grep -qiE 'listening|started server'; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "${ok}" -ne 1 ]]; then
  warn "DbGate Neo4j injoignable — logs :"
  docker logs --tail=40 wise-eat-neo4j-dbgate 2>&1 | sed 's/^/[wise-eat]   /'
  die "Échec — vérifier wise-eat-neo4j healthy + credentials NEO4J_*"
fi

log "OK  DbGate Neo4j sur :${NEO4J_DBGATE_PORT} (→ conteneur :3000)"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-neo4j-admin.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-neo4j-admin-ssl.sh" 2>/dev/null || true
  nginx_test_and_reload || true
fi

log "Terminé — https://${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}"
