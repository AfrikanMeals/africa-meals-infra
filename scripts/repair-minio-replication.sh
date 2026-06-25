#!/usr/bin/env bash
# Répare site replication MinIO après échec initial (buckets créés sur réplicas).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/minio-replication.sh
source "${SCRIPT_DIR}/lib/minio-replication.sh"

require_root
cd "${MINIO_DIR}"

if [[ ! -f .env.minio ]]; then
  die "MinIO non installé — lancer : sudo ./install.sh minio-replication"
fi

set -a && source .env.minio && set +a

if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-minio-replica-1'; then
  die "Réplicas absents — lancer : sudo ./install.sh minio-replication"
fi

configure_minio_site_replication_mc
log "Site replication réparée"
