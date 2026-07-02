#!/usr/bin/env bash
# Répare Matomo (502, HTTP 500, crash post-update, permissions, proxy HTTPS).
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
MATOMO_REPAIR_FRESH="${MATOMO_REPAIR_FRESH:-0}"

matomo_dump_logs() {
  warn "=== Diagnostics Matomo ==="
  docker logs --tail=30 wise-eat-matomo-db 2>&1 | sed 's/^/[wise-eat-db] /' || true
  docker logs --tail=40 wise-eat-matomo 2>&1 | sed 's/^/[wise-eat-app] /' || true
  docker exec wise-eat-matomo tail -n 40 /var/log/apache2/error.log 2>/dev/null \
    | sed 's/^/[apache-err] /' || true
  docker exec wise-eat-matomo sh -c 'for f in /var/www/html/tmp/logs/*.log; do
    [ -f "$f" ] && echo "--- $f ---" && tail -n 30 "$f";
  done' 2>/dev/null | sed 's/^/[matomo-log] /' || true
  if [[ -f "${MATOMO_DATA_DIR}/html/config/config.ini.php" ]]; then
    warn "config.ini.php [database] (sans mot de passe) :"
    grep -E '^(host|username|dbname|tables_prefix|adapter) ' "${MATOMO_DATA_DIR}/html/config/config.ini.php" 2>/dev/null \
      | sed 's/^/[config] /' || true
  else
    warn "config.ini.php absent — assistant d'installation requis"
  fi
}

matomo_http_ok() {
  local code
  code="$(curl -sf -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${MATOMO_HTTP_PORT}/" 2>/dev/null || echo 000)"
  [[ "${code}" =~ ^(200|302|301)$ ]]
}

log "=== Réparation Matomo (${MATOMO_DOMAIN}) ==="

if [[ "${MATOMO_REPAIR_FRESH}" == "1" ]]; then
  ts="$(date +%Y%m%d%H%M%S)"
  for f in config.ini.php config.ini.php.bak; do
    if [[ -f "${MATOMO_DATA_DIR}/html/config/${f}" ]]; then
      mv "${MATOMO_DATA_DIR}/html/config/${f}" "${MATOMO_DATA_DIR}/html/config/${f}.repair.${ts}"
      log "Config sauvegardée : config/${f}.repair.${ts}"
    fi
  done
  rm -rf "${MATOMO_DATA_DIR}/html/tmp/cache/"* 2>/dev/null || true
  log "Mode MATOMO_REPAIR_FRESH=1 — réinstallation web requise après repair"
fi

if [[ -d "${MATOMO_DATA_DIR}/html" ]]; then
  log "Permissions volume Matomo (www-data 33:33)"
  mkdir -p "${MATOMO_DATA_DIR}/html/tmp/logs" "${MATOMO_DATA_DIR}/html/tmp/cache" \
    "${MATOMO_DATA_DIR}/html/tmp/assets" "${MATOMO_DATA_DIR}/html/tmp/tcpdf" \
    "${MATOMO_DATA_DIR}/html/tmp/sessions" "${MATOMO_DATA_DIR}/html/config"
  chown -R 33:33 "${MATOMO_DATA_DIR}/html" 2>/dev/null || true
  find "${MATOMO_DATA_DIR}/html" -type d -exec chmod 775 {} + 2>/dev/null || true
  find "${MATOMO_DATA_DIR}/html" -type f -exec chmod 664 {} + 2>/dev/null || true
  mkdir -p "${MATOMO_DATA_DIR}/html/misc/wise-eat"
  cp -f "${MATOMO_DIR}/bin/sync-config-from-env.php" "${MATOMO_DATA_DIR}/html/misc/wise-eat/"
  chown 33:33 "${MATOMO_DATA_DIR}/html/misc/wise-eat/sync-config-from-env.php" 2>/dev/null || true
fi

log "Recréation conteneurs Matomo"
docker compose --env-file .env.matomo up -d --force-recreate

log "Attente MariaDB healthy (max 90s)…"
for i in $(seq 1 45); do
  if docker inspect wise-eat-matomo-db --format '{{.State.Health.Status}}' 2>/dev/null | grep -qx healthy; then
    break
  fi
  sleep 2
done

if docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null; then
  log "Sync config.ini.php ← .env.matomo (host matomo-db, user matomo)"
  sync_out="$(docker exec wise-eat-matomo php /var/www/html/misc/wise-eat/sync-config-from-env.php 2>&1)" || true
  echo "${sync_out}" | sed 's/^/[wise-eat] /'
  if echo "${sync_out}" | grep -q '^PDO_FAIL:'; then
    warn "Base inaccessible avec .env.matomo — vérifier MATOMO_DB_PASSWORD"
  fi
fi

if docker exec wise-eat-matomo test -f /var/www/html/console 2>/dev/null; then
  log "Finalisation update interrompue (CLI)"
  docker exec wise-eat-matomo php /var/www/html/console core:update --yes 2>&1 | sed 's/^/[core:update] /' || \
    warn "core:update échoué — voir diagnostics"
  docker exec wise-eat-matomo php /var/www/html/console cache:clear 2>/dev/null || true
fi

if docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null; then
  log "Configuration proxy HTTPS (nginx)"
  docker exec wise-eat-matomo php /var/www/html/console config:set --section=General assume_secure_protocol 1 2>/dev/null || true
  docker exec wise-eat-matomo php /var/www/html/console config:set --section=General force_ssl 1 2>/dev/null || true
  docker exec wise-eat-matomo php /var/www/html/console config:set --section=General trusted_hosts "${MATOMO_DOMAIN}" 2>/dev/null || true
fi

log "Test HTTP :127.0.0.1:${MATOMO_HTTP_PORT}"
if matomo_http_ok; then
  log "OK  Matomo répond"
else
  matomo_dump_logs
  die "Matomo renvoie HTTP 500 — voir diagnostics. Si config corrompue : MATOMO_REPAIR_FRESH=1 sudo ./install.sh repair-matomo"
fi

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-matomo-gateway.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-matomo-ssl.sh" 2>/dev/null || true
fi

log "Terminé — https://${MATOMO_DOMAIN}"
log "Mises à jour : sudo ./install.sh update-matomo (éviter l'updater web)"
