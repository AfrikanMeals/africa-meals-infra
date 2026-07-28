#!/usr/bin/env bash
# Crée le Secret K8s neo4j-config depuis neo4j/.env.neo4j (auth + heap).
# Ne commit jamais .env.neo4j — lecture hôte uniquement.
#
# Usage :
#   sudo ./create-neo4j-secret.sh
#   NEO4J_ENV=/path/.env.neo4j ./create-neo4j-secret.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
SECRET_NAME="${K8S_NEO4J_SECRET:-neo4j-config}"
NEO4J_ENV="${NEO4J_ENV:-${INFRA_ROOT}/neo4j/.env.neo4j}"

if [[ ! -f "${NEO4J_ENV}" ]]; then
  echo "Fichier absent : ${NEO4J_ENV} — lancer sudo ./install.sh neo4j d'abord" >&2
  exit 1
fi

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

set -a
# shellcheck disable=SC1090
source "${NEO4J_ENV}"
set +a

: "${NEO4J_PASSWORD:?NEO4J_PASSWORD manquant dans ${NEO4J_ENV}}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_HEAP_INITIAL="${NEO4J_HEAP_INITIAL:-256m}"
NEO4J_HEAP_MAX="${NEO4J_HEAP_MAX:-512m}"
NEO4J_PAGECACHE="${NEO4J_PAGECACHE:-128m}"
NEO4J_BOLT_ADVERTISED="${NEO4J_BOLT_ADVERTISED:-localhost:7687}"
NEO4J_HTTP_ADVERTISED="${NEO4J_HTTP_ADVERTISED:-localhost:7474}"

# Format officiel image Neo4j : user/password (literals = OK si password contient /, #, etc.).
NEO4J_AUTH="${NEO4J_USER}/${NEO4J_PASSWORD}"

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

# --from-literal évite le parse env-file qui casse sur caractères spéciaux du mot de passe.
"${KUBECTL[@]}" create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-literal="NEO4J_AUTH=${NEO4J_AUTH}" \
  --from-literal="NEO4J_USER=${NEO4J_USER}" \
  --from-literal="NEO4J_PASSWORD=${NEO4J_PASSWORD}" \
  --from-literal="NEO4J_HEAP_INITIAL=${NEO4J_HEAP_INITIAL}" \
  --from-literal="NEO4J_HEAP_MAX=${NEO4J_HEAP_MAX}" \
  --from-literal="NEO4J_PAGECACHE=${NEO4J_PAGECACHE}" \
  --from-literal="NEO4J_BOLT_ADVERTISED=${NEO4J_BOLT_ADVERTISED}" \
  --from-literal="NEO4J_HTTP_ADVERTISED=${NEO4J_HTTP_ADVERTISED}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Secret ${SECRET_NAME} appliqué dans ${NAMESPACE} (depuis ${NEO4J_ENV})"
echo "  Auth user=${NEO4J_USER} · heap ${NEO4J_HEAP_INITIAL}/${NEO4J_HEAP_MAX} · pagecache ${NEO4J_PAGECACHE}"
echo "  API : NEO4J_URI=bolt://host.k3s.internal:7687 (password = .env.neo4j)"
