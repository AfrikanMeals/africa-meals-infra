#!/usr/bin/env bash
# Neo4j Community — Docker sur le VPS Wise Eat (1 Go RAM, volume 5 Go).
# Usage : sudo ./install.sh neo4j
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/neo4j-storage.sh
source "${SCRIPT_DIR}/lib/neo4j-storage.sh"

require_root
sync_component neo4j
cd "${NEO4J_DIR}"
ensure_docker
ensure_wise_eat_infra_network

if [[ ! -f .env.neo4j ]]; then
  NEO4J_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  cp .env.example .env.neo4j
  sed -i "s|^NEO4J_PASSWORD=.*|NEO4J_PASSWORD=${NEO4J_PASSWORD}|" .env.neo4j
  chmod 600 .env.neo4j
  log "Secrets Neo4j générés → ${NEO4J_DIR}/.env.neo4j"
fi

set -a && source .env.neo4j && set +a

: "${NEO4J_PASSWORD:?NEO4J_PASSWORD manquant dans .env.neo4j}"

NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_HTTP_PORT="${NEO4J_HTTP_PORT:-7474}"
NEO4J_BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
NEO4J_DATA_DIR="${NEO4J_DATA_DIR:-/var/lib/wise-eat/neo4j}"
NEO4J_STORAGE_GB="${NEO4J_STORAGE_GB:-5}"
NEO4J_MEM_LIMIT="${NEO4J_MEM_LIMIT:-1g}"
NEO4J_HEAP_MAX="${NEO4J_HEAP_MAX:-512m}"
NEO4J_PAGECACHE="${NEO4J_PAGECACHE:-128m}"

ensure_neo4j_data_volume
persist_neo4j_env_paths
set -a && source .env.neo4j && set +a

mkdir -p "${NEO4J_DBGATE_DATA:-./data-dbgate}"

log "Démarrage Neo4j Docker (RAM ${NEO4J_MEM_LIMIT}, données ${NEO4J_DATA_DIR}, ${NEO4J_STORAGE_GB}G)"
docker compose --env-file .env.neo4j down 2>/dev/null || true
docker compose --env-file .env.neo4j pull
docker compose --env-file .env.neo4j up -d

wait_for_neo4j() {
  local i
  for i in $(seq 1 60); do
    if curl -sf --max-time 3 "http://127.0.0.1:${NEO4J_HTTP_PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    if docker exec wise-eat-neo4j wget -q --spider "http://127.0.0.1:7474" 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

if ! wait_for_neo4j; then
  docker compose --env-file .env.neo4j logs --tail=40 neo4j || true
  die "Neo4j ne répond pas sur :${NEO4J_HTTP_PORT} / :${NEO4J_BOLT_PORT} — voir docker logs wise-eat-neo4j"
fi

docker compose --env-file .env.neo4j ps

cat <<EOF

Neo4j Community installé dans ${NEO4J_DIR}

Local Browser : http://127.0.0.1:${NEO4J_HTTP_PORT}
Local Bolt    : bolt://127.0.0.1:${NEO4J_BOLT_PORT}
Admin public  : sudo STUNNEL_TLS_EMAIL=… ./install.sh neo4j-admin  → https://db-graph.wise-eat.com
k3s Bolt      : bolt://host.k3s.internal:${NEO4J_BOLT_PORT}  (si CNI gateway exposé)
Volume        : ${NEO4J_DATA_DIR} (${NEO4J_STORAGE_GB}G max)
RAM conteneur : ${NEO4J_MEM_LIMIT} (heap max ${NEO4J_HEAP_MAX}, pagecache ${NEO4J_PAGECACHE})
User          : ${NEO4J_USER}
Password      : (voir NEO4J_PASSWORD dans ${NEO4J_DIR}/.env.neo4j)

API (.env prod) — kill-switch off par défaut :
  NEO4J_ENABLED=false
  # Après validation :
  # NEO4J_ENABLED=true
  # NEO4J_URI=bolt://host.k3s.internal:${NEO4J_BOLT_PORT}
  # NEO4J_USER=${NEO4J_USER}
  # NEO4J_PASSWORD=***
  # NEO4J_DATABASE=neo4j
  # RECO_GRAPH_ENABLED=false
  # GRAPH_SYNC_ENABLED=false

Test :
  docker exec -it wise-eat-neo4j cypher-shell -u ${NEO4J_USER} -p '***' 'RETURN 1 AS ok;'

EOF
