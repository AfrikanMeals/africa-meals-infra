#!/usr/bin/env bash
# Répare DbGate + nginx (data.wise-eat.com 502).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component mongodb
cd "${MONGODB_DIR}"

[[ -f .env.mongodb ]] || die ".env.mongodb absent — sudo ./install.sh mongodb"

if grep -qE '^MONGO_BACKUP_CRON=30 3' .env.mongodb 2>/dev/null; then
  sed -i 's|^MONGO_BACKUP_CRON=30 3 \* \* \*|MONGO_BACKUP_CRON="30 3 * * *"|' .env.mongodb
fi

# Migration mongo-express → dbgate
if grep -q '^MONGO_EXPRESS_PORT=' .env.mongodb 2>/dev/null \
  && ! grep -q '^MONGO_DBGATE_PORT=' .env.mongodb 2>/dev/null; then
  port="$(grep '^MONGO_EXPRESS_PORT=' .env.mongodb | cut -d= -f2)"
  echo "MONGO_DBGATE_PORT=${port}" >> .env.mongodb
fi

set -a && source .env.mongodb && set +a
MONGO_DBGATE_PORT="${MONGO_DBGATE_PORT:-${MONGO_EXPRESS_PORT:-8081}}"

log "=== Réparation DbGate (data.wise-eat.com) ==="

bash "${SCRIPT_DIR}/repair-mongodb-replicaset.sh"

docker rm -f wise-eat-mongo-express 2>/dev/null || true
mkdir -p "${MONGO_DBGATE_DATA:-./data-dbgate}"

log "Recréation DbGate"
docker compose --env-file .env.mongodb up -d --force-recreate dbgate

log "Attente DbGate (max 90s)…"
ok=0
for i in $(seq 1 45); do
  code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MONGO_DBGATE_PORT}/" 2>/dev/null || echo 000)"
  if [[ "${code}" =~ ^(200|302|401)$ ]]; then
    ok=1
    break
  fi
  if docker logs wise-eat-dbgate 2>&1 | grep -qiE 'listening|started server'; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "${ok}" -ne 1 ]]; then
  warn "DbGate injoignable — logs :"
  docker logs --tail=40 wise-eat-dbgate 2>&1 | sed 's/^/[wise-eat]   /'
  die "Échec — vérifier rs.status() et URL_wiseeat dans docker-compose.yml"
fi

log "OK  DbGate sur :${MONGO_DBGATE_PORT} (→ conteneur :3000)"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-mongodb-admin.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-mongodb-admin-ssl.sh" 2>/dev/null || true
  nginx_test_and_reload || true
fi

log "Terminé — https://${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
