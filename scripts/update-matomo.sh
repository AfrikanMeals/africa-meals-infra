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
MATOMO_DOMAIN="${MATOMO_DOMAIN:-analytics.wise-eat.com}"
MATOMO_HTTP_PORT="${MATOMO_HTTP_PORT:-8089}"
MATOMO_DATA_DIR="${MATOMO_DATA_DIR:-/var/lib/wise-eat/matomo}"

log "=== Mise à jour Matomo (image Docker + resync vendor + core:update) ==="

mkdir -p "${MATOMO_DATA_DIR}/html/misc/wise-eat"
cp -f "${MATOMO_DIR}/bin/resync-core-from-image.sh" "${MATOMO_DATA_DIR}/html/misc/wise-eat/"
chmod +x "${MATOMO_DATA_DIR}/html/misc/wise-eat/resync-core-from-image.sh" 2>/dev/null || true

docker compose --env-file .env.matomo pull matomo
docker compose --env-file .env.matomo up -d --force-recreate matomo

for i in $(seq 1 45); do
  if docker inspect wise-eat-matomo-db --format '{{.State.Health.Status}}' 2>/dev/null | grep -qx healthy; then
    break
  fi
  sleep 2
done

log "Resync vendor/core depuis la nouvelle image"
docker exec wise-eat-matomo bash /var/www/html/misc/wise-eat/resync-core-from-image.sh 2>&1 | sed 's/^/[resync] /'

if docker exec wise-eat-matomo test -f /var/www/html/console 2>/dev/null; then
  docker exec wise-eat-matomo php /var/www/html/console core:update --yes 2>&1 | sed 's/^/[core:update] /'
  docker exec wise-eat-matomo php /var/www/html/console cache:clear 2>/dev/null || true
else
  die "Matomo non installé — terminer l'assistant sur https://${MATOMO_DOMAIN}"
fi

docker compose --env-file .env.matomo ps
log "Matomo à jour — https://${MATOMO_DOMAIN}"
