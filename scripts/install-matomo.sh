#!/usr/bin/env bash
# Matomo Analytics — Docker (MariaDB + Apache) sur le VPS Wise Eat.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/matomo-storage.sh
source "${SCRIPT_DIR}/lib/matomo-storage.sh"

require_root
sync_component matomo
cd "${MATOMO_DIR}"
ensure_docker

if [[ ! -f .env.matomo ]]; then
  MATOMO_DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  MATOMO_DB_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  cp .env.example .env.matomo
  sed -i "s|^MATOMO_DB_PASSWORD=.*|MATOMO_DB_PASSWORD=${MATOMO_DB_PASSWORD}|" .env.matomo
  sed -i "s|^MATOMO_DB_ROOT_PASSWORD=.*|MATOMO_DB_ROOT_PASSWORD=${MATOMO_DB_ROOT_PASSWORD}|" .env.matomo
  chmod 600 .env.matomo
  log "Secrets Matomo générés → ${MATOMO_DIR}/.env.matomo"
fi

set -a && source .env.matomo && set +a

: "${MATOMO_DB_PASSWORD:?MATOMO_DB_PASSWORD manquant dans .env.matomo}"
: "${MATOMO_DB_ROOT_PASSWORD:?MATOMO_DB_ROOT_PASSWORD manquant dans .env.matomo}"

MATOMO_DOMAIN="${MATOMO_DOMAIN:-analytics.wise-eat.com}"
MATOMO_ROOT_URL="${MATOMO_ROOT_URL:-https://${MATOMO_DOMAIN}/}"
MATOMO_HTTP_PORT="${MATOMO_HTTP_PORT:-8089}"
MATOMO_DATA_DIR="${MATOMO_DATA_DIR:-/var/lib/wise-eat/matomo}"

ensure_matomo_data_volume
persist_matomo_env_paths
set -a && source .env.matomo && set +a

log "Démarrage Matomo Docker (données : ${MATOMO_DATA_DIR})"
docker compose --env-file .env.matomo down 2>/dev/null || true
docker compose --env-file .env.matomo pull
docker compose --env-file .env.matomo up -d

wait_for_matomo() {
  local port="$1"
  local i
  for i in $(seq 1 60); do
    if curl -sf --max-time 3 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

if ! wait_for_matomo "${MATOMO_HTTP_PORT}"; then
  die "Matomo ne répond pas sur :${MATOMO_HTTP_PORT} — voir docker logs wise-eat-matomo"
fi

docker compose --env-file .env.matomo ps

if command -v nginx >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/install-matomo-gateway.sh" 2>/dev/null || \
    warn "nginx Matomo non configuré — lancer : sudo STUNNEL_TLS_EMAIL=... ./install.sh matomo-gateway"
fi

cat <<EOF

Matomo Analytics installé dans ${MATOMO_DIR}

Public (après TLS) : ${MATOMO_ROOT_URL}
Local              : http://127.0.0.1:${MATOMO_HTTP_PORT}
Volume             : ${MATOMO_DATA_DIR} (${MATOMO_STORAGE_GB:-5}G max)

Première visite (assistant base de données) :
  Database Server : matomo-db
  Login           : ${MATOMO_DB_USER:-matomo}
  Password        : (voir MATOMO_DB_PASSWORD dans ${MATOMO_DIR}/.env.matomo)
  Database Name   : ${MATOMO_DB_NAME:-matomo}
  Table Prefix    : matomo_
  Adapter         : PDO\\MYSQL

  Sur le VPS : sudo grep MATOMO_DB_ ${MATOMO_DIR}/.env.matomo

Ensuite :
  1. Terminer l'assistant (compte super utilisateur)
  2. Administration → Système → Général → URL Matomo = ${MATOMO_ROOT_URL}
  3. Activer « Utiliser un protocole sécurisé (HTTPS) » si derrière nginx TLS

Snippet tracking (site web) :
  <!-- Matomo -->
  <script>
    var _paq = window._paq = window._paq || [];
    _paq.push(['trackPageView']);
    _paq.push(['enableLinkTracking']);
    (function() {
      var u="${MATOMO_ROOT_URL}";
      _paq.push(['setTrackerUrl', u+'matomo.php']);
      _paq.push(['setSiteId', '1']);
      var d=document, g=d.createElement('script'), s=d.getElementsByTagName('script')[0];
      g.async=true; g.src=u+'matomo.js'; s.parentNode.insertBefore(g,s);
    })();
  </script>
  <!-- End Matomo -->

TLS :
  sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh matomo-gateway
  # ou certificat global :
  sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot
EOF
