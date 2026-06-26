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

# Replica set PRIMARY obligatoire — ne pas recréer mongo-1 ici
bash "${SCRIPT_DIR}/repair-mongodb-replicaset.sh"

log "Recréation mongo-express uniquement"
docker compose --env-file .env.mongodb up -d --force-recreate mongo-express

log "Attente Mongo Express (max 90s)…"
ok=0
for i in $(seq 1 45); do
  if docker logs wise-eat-mongo-express 2>&1 | grep -q 'Mongo Express server listening'; then
    ok=1
    break
  fi
  if curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MONGO_EXPRESS_PORT:-8081}/" 2>/dev/null | grep -qE '^(200|302|401)'; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "${ok}" -ne 1 ]]; then
  warn "Mongo Express injoignable — logs :"
  docker logs --tail=40 wise-eat-mongo-express 2>&1 | sed 's/^/[wise-eat]   /'
  die "Échec — vérifier rs.status() et ME_CONFIG_MONGODB_URL"
fi

log "OK  Mongo Express sur :${MONGO_EXPRESS_PORT:-8081}"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-mongodb-admin.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-mongodb-admin-ssl.sh" 2>/dev/null || true
  nginx_test_and_reload || true
fi

log "Terminé — https://${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
