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
MATOMO_DB_USER="${MATOMO_DB_USER:-matomo}"
MATOMO_DB_NAME="${MATOMO_DB_NAME:-matomo}"

matomo_copy_helpers() {
  mkdir -p "${MATOMO_DATA_DIR}/html/misc/wise-eat"
  cp -f "${MATOMO_DIR}/bin/sync-config-from-env.php" "${MATOMO_DATA_DIR}/html/misc/wise-eat/"
  cp -f "${MATOMO_DIR}/bin/diagnose-boot.php" "${MATOMO_DATA_DIR}/html/misc/wise-eat/"
  cp -f "${MATOMO_DIR}/bin/resync-core-from-image.sh" "${MATOMO_DATA_DIR}/html/misc/wise-eat/"
  chmod +x "${MATOMO_DATA_DIR}/html/misc/wise-eat/resync-core-from-image.sh" 2>/dev/null || true
  chown -R 33:33 "${MATOMO_DATA_DIR}/html/misc/wise-eat" 2>/dev/null || true
}

matomo_resync_core() {
  log "Resync vendor/core depuis l'image Docker (fix Composer autoload)"
  docker exec wise-eat-matomo bash /var/www/html/misc/wise-eat/resync-core-from-image.sh 2>&1 | sed 's/^/[resync] /'
}

matomo_curl() {
  curl -sf -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Host: ${MATOMO_DOMAIN}" \
    -H "X-Forwarded-Proto: https" \
    -H "X-Forwarded-For: 127.0.0.1" \
    "http://127.0.0.1:${MATOMO_HTTP_PORT}/" 2>/dev/null || echo 000
}

matomo_http_ok() {
  local code
  code="$(matomo_curl)"
  [[ "${code}" =~ ^(200|302|301)$ ]]
}

matomo_table_count() {
  local pattern="$1"
  docker exec wise-eat-matomo-db mariadb -u "${MATOMO_DB_USER}" -p"${MATOMO_DB_PASSWORD}" \
    "${MATOMO_DB_NAME}" -N -e "SHOW TABLES LIKE '${pattern}';" 2>/dev/null | wc -l | tr -d ' '
}

matomo_detect_prefix() {
  local c_m c_a
  c_m="$(matomo_table_count 'matomo\_%')"
  c_a="$(matomo_table_count 'analytic\_%')"
  if [[ "${c_m}" -gt 0 ]]; then
    echo "matomo_"
  elif [[ "${c_a}" -gt 0 ]]; then
    echo "analytic_"
  else
    echo ""
  fi
}

matomo_dump_logs() {
  warn "=== Diagnostics Matomo ==="
  docker exec wise-eat-matomo tail -n 50 /var/log/apache2/error.log 2>&1 \
    | sed 's/^/[apache-err] /' || true
  docker exec wise-eat-matomo sh -c 'for f in /var/www/html/tmp/logs/*.log; do
    [ -f "$f" ] && echo "--- $f ---" && tail -n 40 "$f";
  done' 2>&1 | sed 's/^/[matomo-log] /' || true
  docker exec -e MATOMO_DIAG_HOST="${MATOMO_DOMAIN}" wise-eat-matomo \
    php /var/www/html/misc/wise-eat/diagnose-boot.php 2>&1 | sed 's/^/[boot] /' || true
  local code body
  code="$(matomo_curl)"
  body="$(curl -s --max-time 8 \
    -H "Host: ${MATOMO_DOMAIN}" \
    -H "X-Forwarded-Proto: https" \
    "http://127.0.0.1:${MATOMO_HTTP_PORT}/" 2>/dev/null | head -c 500 || true)"
  warn "HTTP via proxy headers : ${code} — ${body}"
  if [[ -f "${MATOMO_DATA_DIR}/html/config/config.ini.php" ]]; then
    grep -E '^(host|username|dbname|tables_prefix|adapter|force_ssl|assume_secure_protocol) ' \
      "${MATOMO_DATA_DIR}/html/config/config.ini.php" 2>/dev/null | sed 's/^/[config] /' || true
  fi
  local prefix c_m c_a
  prefix="$(matomo_detect_prefix || true)"
  c_m="$(matomo_table_count 'matomo\_%')"
  c_a="$(matomo_table_count 'analytic\_%')"
  warn "Tables DB : matomo_*=${c_m} analytic_*=${c_a} (prefix détecté : ${prefix:-aucun})"
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
fi

if [[ -d "${MATOMO_DATA_DIR}/html" ]]; then
  log "Permissions volume Matomo (www-data 33:33)"
  mkdir -p "${MATOMO_DATA_DIR}/html/tmp/logs" "${MATOMO_DATA_DIR}/html/tmp/cache" \
    "${MATOMO_DATA_DIR}/html/tmp/assets" "${MATOMO_DATA_DIR}/html/tmp/tcpdf" \
    "${MATOMO_DATA_DIR}/html/tmp/sessions" "${MATOMO_DATA_DIR}/html/config"
  matomo_copy_helpers
  chown -R 33:33 "${MATOMO_DATA_DIR}/html" 2>/dev/null || true
  find "${MATOMO_DATA_DIR}/html" -type d -exec chmod 775 {} + 2>/dev/null || true
  find "${MATOMO_DATA_DIR}/html" -type f -exec chmod 664 {} + 2>/dev/null || true
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

detected_prefix="$(matomo_detect_prefix || true)"
if [[ -n "${detected_prefix}" ]]; then
  export MATOMO_DATABASE_TABLES_PREFIX="${detected_prefix}"
  log "Préfixe tables détecté en DB : ${detected_prefix}"
elif docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null; then
  warn "config.ini.php présent mais aucune table Matomo — réinitialisation config pour relancer l'assistant"
  ts="$(date +%Y%m%d%H%M%S)"
  mv "${MATOMO_DATA_DIR}/html/config/config.ini.php" \
    "${MATOMO_DATA_DIR}/html/config/config.ini.php.incomplete.${ts}" 2>/dev/null || true
fi

if docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null; then
  log "Sync config.ini.php ← .env.matomo"
  sync_out="$(docker exec \
    -e MATOMO_DATABASE_HOST=matomo-db \
    -e MATOMO_DATABASE_USERNAME="${MATOMO_DB_USER}" \
    -e MATOMO_DATABASE_PASSWORD="${MATOMO_DB_PASSWORD}" \
    -e MATOMO_DATABASE_DBNAME="${MATOMO_DB_NAME}" \
    -e MATOMO_DATABASE_TABLES_PREFIX="${MATOMO_DATABASE_TABLES_PREFIX:-matomo_}" \
    -e MATOMO_DATABASE_ADAPTER='PDO\MYSQL' \
    wise-eat-matomo php /var/www/html/misc/wise-eat/sync-config-from-env.php 2>&1)" || true
  echo "${sync_out}" | sed 's/^/[wise-eat] /'
fi

if [[ -n "${detected_prefix}" ]]; then
  boot_out="$(docker exec -e MATOMO_DIAG_HOST="${MATOMO_DOMAIN}" wise-eat-matomo \
    php /var/www/html/misc/wise-eat/diagnose-boot.php 2>&1)" || true
  if echo "${boot_out}" | grep -qE 'ComposerAutoloader|BOOT_FAIL'; then
    warn "vendor/composer corrompu — resync depuis l'image"
    matomo_resync_core
  fi
fi

if docker exec wise-eat-matomo test -f /var/www/html/console 2>/dev/null \
  && docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null \
  && [[ -n "${detected_prefix}" ]]; then
  log "Finalisation update interrompue (CLI)"
  docker exec wise-eat-matomo php /var/www/html/console core:update --yes 2>&1 | sed 's/^/[core:update] /' || \
    warn "core:update échoué"
  docker exec wise-eat-matomo php /var/www/html/console cache:clear 2>/dev/null || true
fi

log "Test HTTP (headers nginx simulés) :127.0.0.1:${MATOMO_HTTP_PORT}"
if matomo_http_ok; then
  log "OK  Matomo répond"
  if docker exec wise-eat-matomo test -f /var/www/html/config/config.ini.php 2>/dev/null; then
    docker exec wise-eat-matomo php /var/www/html/console config:set --section=General assume_secure_protocol 1 2>/dev/null || true
    docker exec wise-eat-matomo php /var/www/html/console config:set --section=General force_ssl 1 2>/dev/null || true
    docker exec wise-eat-matomo php /var/www/html/console config:set --section=General trusted_hosts "${MATOMO_DOMAIN}" 2>/dev/null || true
  fi
else
  matomo_dump_logs
  die "Matomo HTTP 500 — voir [boot] / [apache-err] ci-dessus. Si aucune table : MATOMO_REPAIR_FRESH=1 sudo ./install.sh repair-matomo"
fi

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-matomo-gateway.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/enable-matomo-ssl.sh" 2>/dev/null || true
fi

log "Terminé — https://${MATOMO_DOMAIN}"
