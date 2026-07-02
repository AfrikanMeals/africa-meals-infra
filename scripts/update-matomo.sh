#!/usr/bin/env bash
# Mise à jour Matomo via CLI (recommandé sur VPS — évite crash updater web).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
sync_component matomo
cd "${MATOMO_DIR}"

[[ -f .env.matomo ]] || die ".env.matomo absent — sudo ./install.sh matomo"

set -a && source .env.matomo && set +a
MATOMO_HTTP_PORT="${MATOMO_HTTP_PORT:-8089}"

log "=== Mise à jour Matomo (image Docker + core:update) ==="

docker compose --env-file .env.matomo pull matomo
docker compose --env-file .env.matomo up -d --force-recreate matomo

for i in $(seq 1 45); do
  if curl -sf --max-time 3 "http://127.0.0.1:${MATOMO_HTTP_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if docker exec wise-eat-matomo test -f /var/www/html/console 2>/dev/null; then
  docker exec wise-eat-matomo php /var/www/html/console core:update --yes
  docker exec wise-eat-matomo php /var/www/html/console cache:clear
else
  die "Matomo non installé — terminer l'assistant sur https://${MATOMO_DOMAIN:-analytics.wise-eat.com}"
fi

docker compose --env-file .env.matomo ps
log "Matomo à jour — https://${MATOMO_DOMAIN:-analytics.wise-eat.com}"
