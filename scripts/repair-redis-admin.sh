#!/usr/bin/env bash
# Répare RedisInsight + nginx (redis.wise-eat.com 502).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component redis
cd "${REDIS_DIR}"

[[ -f .env.redis ]] || die ".env.redis absent — sudo ./install.sh redis"

set -a && source .env.redis && set +a
REDISINSIGHT_PORT="${REDISINSIGHT_PORT:-5540}"

log "=== Réparation RedisInsight (redis.wise-eat.com) ==="

# Redis joignable sur l’hôte ? (Docker ou k8s hostPort)
if ! (echo >/dev/tcp/127.0.0.1/6379) 2>/dev/null; then
  warn "Rien n’écoute sur 127.0.0.1:6379 — démarrer Redis (Docker ou k8s) avant l’UI"
fi

mkdir -p "${REDISINSIGHT_DATA:-./data-redisinsight}"
chown -R 1000:1000 "${REDISINSIGHT_DATA:-./data-redisinsight}" 2>/dev/null || true

log "Recréation RedisInsight"
docker compose -f docker-compose.redisinsight.yml --env-file .env.redis up -d --force-recreate

log "Attente RedisInsight (max 90s)…"
ok=0
for _ in $(seq 1 45); do
  code="$(curl -sf -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${REDISINSIGHT_PORT}/api/health/" 2>/dev/null || echo 000)"
  if [[ "${code}" =~ ^(200|204)$ ]]; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "${ok}" -ne 1 ]]; then
  warn "RedisInsight injoignable — logs :"
  docker logs --tail=40 wise-eat-redisinsight 2>&1 | sed 's/^/[wise-eat]   /' || true
  die "Échec — vérifier CACHE_REDIS_PASSWORD / ports 6379–6380"
fi

log "OK  RedisInsight sur :${REDISINSIGHT_PORT}"

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-redis-admin.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-redis-admin-ssl.sh" 2>/dev/null || true
  nginx_test_and_reload || true
fi

log "Terminé — https://${REDIS_ADMIN_DOMAIN:-redis.wise-eat.com}"
