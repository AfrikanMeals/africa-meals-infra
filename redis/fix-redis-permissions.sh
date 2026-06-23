#!/usr/bin/env bash
# Corrige les permissions Redis Docker (UID 999) — ACL + volumes data.
# Usage : sudo bash fix-redis-permissions.sh [répertoire redis, défaut /opt/wise-eat/redis]
set -euo pipefail

REDIS_DIR="${1:-/opt/wise-eat/redis}"
cd "${REDIS_DIR}"

for f in cache-users.acl bull-users.acl; do
  if [[ -f "${f}" ]]; then
    chown 999:999 "${f}"
    chmod 600 "${f}"
    echo "OK ${f} → 999:999"
  else
    echo "WARN ${f} absent — regénérer via docs/REDIS_VPS_PRODUCTION.md étape 3" >&2
  fi
done

mkdir -p data-cache data-bullmq
chown -R 999:999 data-cache data-bullmq
echo "OK data-cache data-bullmq → 999:999"

if command -v docker >/dev/null 2>&1; then
  docker compose up -d
  sleep 2
  docker compose ps
fi
