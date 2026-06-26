#!/usr/bin/env bash
# Répare Mongo Express + nginx (data.wise-eat.com 502).
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

set -a && source .env.mongodb && set +a

log "=== Réparation Mongo Express (data.wise-eat.com) ==="

if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-mongo-1'; then
  die "MongoDB absent — sudo ./install.sh mongodb"
fi

log "Recréation wise-eat-mongo-1 (alias réseau mongo) + mongo-express"
docker compose --env-file .env.mongodb up -d --force-recreate mongo-1 mongo-express

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${MONGO_EXPRESS_PORT:-8081}/" >/dev/null 2>&1; then
    log "OK  Mongo Express répond sur :${MONGO_EXPRESS_PORT:-8081}"
    break
  fi
  if docker logs --tail=5 wise-eat-mongo-express 2>&1 | grep -q 'Mongo Express server listening'; then
    log "OK  Mongo Express démarré"
    break
  fi
  sleep 2
done

if ! curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MONGO_EXPRESS_PORT:-8081}/" | grep -qE '^(200|302|401)'; then
  warn "Mongo Express injoignable — logs :"
  docker logs --tail=30 wise-eat-mongo-express 2>&1 | sed 's/^/[wise-eat]   /'
  die "Vérifier ME_CONFIG_MONGODB_URL et rs.status()"
fi

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-mongodb-admin.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-mongodb-admin-ssl.sh" 2>/dev/null || true
  nginx_test_and_reload || true
fi

log "Terminé — https://${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
