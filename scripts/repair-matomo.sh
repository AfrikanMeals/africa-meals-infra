#!/usr/bin/env bash
# Répare Matomo (502, crash post-update, permissions, proxy HTTPS).
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
MATOMO_ROOT_URL="${MATOMO_ROOT_URL:-https://${MATOMO_DOMAIN}/}"
MATOMO_HTTP_PORT="${MATOMO_HTTP_PORT:-8089}"
MATOMO_DATA_DIR="${MATOMO_DATA_DIR:-/var/lib/wise-eat/matomo}"

log "=== Réparation Matomo (${MATOMO_DOMAIN}) ==="

if [[ -d "${MATOMO_DATA_DIR}/html" ]]; then
  log "Permissions volume Matomo (www-data 33:33)"
  chown -R 33:33 "${MATOMO_DATA_DIR}/html" 2>/dev/null || true
  find "${MATOMO_DATA_DIR}/html" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "${MATOMO_DATA_DIR}/html" -type f -exec chmod 644 {} + 2>/dev/null || true
fi

log "Recréation conteneurs Matomo"
docker compose --env-file .env.matomo up -d --force-recreate

log "Attente MariaDB + Matomo (max 120s)…"
ok=0
for i in $(seq 1 60); do
  db_ok=0
  app_ok=0
  if docker inspect wise-eat-matomo-db --format '{{.State.Health.Status}}' 2>/dev/null | grep -qx healthy; then
    db_ok=1
  fi
  if curl -sf --max-time 3 "http://127.0.0.1:${MATOMO_HTTP_PORT}/" >/dev/null 2>&1; then
    app_ok=1
  fi
  if [[ "${db_ok}" -eq 1 && "${app_ok}" -eq 1 ]]; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "${ok}" -ne 1 ]]; then
  warn "Matomo ou MariaDB injoignable — logs :"
  docker logs --tail=40 wise-eat-matomo-db 2>&1 | sed 's/^/[wise-eat-db] /'
  docker logs --tail=60 wise-eat-matomo 2>&1 | sed 's/^/[wise-eat-app] /'
  die "Échec — voir logs ci-dessus"
fi

log "Test connexion DB depuis conteneur Matomo"
if ! docker exec wise-eat-matomo php -r "
  \$h = getenv('MATOMO_DATABASE_HOST') ?: 'matomo-db';
  \$u = getenv('MATOMO_DATABASE_USERNAME') ?: 'matomo';
  \$p = getenv('MATOMO_DATABASE_PASSWORD') ?: '';
  \$d = getenv('MATOMO_DATABASE_DBNAME') ?: 'matomo';
  new PDO('mysql:host='.\$h.';dbname='.\$d, \$u, \$p);
  echo 'OK';
" 2>/dev/null | grep -qx OK; then
  warn "Connexion PDO échouée — vérifier ${MATOMO_DIR}/.env.matomo (host matomo-db, user matomo, db matomo)"
fi

CONFIG="${MATOMO_DATA_DIR}/html/config/config.ini.php"
if docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null; then
  log "Configuration proxy HTTPS (nginx)"
  docker exec wise-eat-matomo php /var/www/html/console config:set --section=General assume_secure_protocol 1 2>/dev/null || true
  docker exec wise-eat-matomo php /var/www/html/console config:set --section=General force_ssl 1 2>/dev/null || true
  docker exec wise-eat-matomo php /var/www/html/console config:set --section=General trusted_hosts "${MATOMO_DOMAIN}" 2>/dev/null || true
fi

if docker exec wise-eat-matomo test -f /var/www/html/console 2>/dev/null; then
  log "Finalisation update interrompue (CLI)"
  docker exec wise-eat-matomo php /var/www/html/console core:update --yes 2>/dev/null || \
    warn "core:update ignoré (installation peut-être incomplète)"
  docker exec wise-eat-matomo php /var/www/html/console cache:clear 2>/dev/null || true
fi

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-matomo-gateway.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-matomo-ssl.sh" 2>/dev/null || true
fi

log "Terminé — https://${MATOMO_DOMAIN}"
log "Mises à jour futures : sudo ./install.sh update-matomo (éviter l'updater web sur VPS 8 Go)"
