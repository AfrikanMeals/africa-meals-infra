#!/usr/bin/env bash
# RedisInsight derrière nginx (redis.wise-eat.com) + basic auth + Certbot optionnel.
# Prérequis : Redis joignable sur host (Docker ou k8s hostPort) :6379 / :6380.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

REDIS_ADMIN_DOMAIN="${REDIS_ADMIN_DOMAIN:-redis.wise-eat.com}"
REDIS_ADMIN_BACKEND_HOST="${REDIS_ADMIN_BACKEND_HOST:-127.0.0.1}"
REDIS_ADMIN_BACKEND_PORT="${REDIS_ADMIN_BACKEND_PORT:-5540}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

sync_component redis
cd "${REDIS_DIR}"
ensure_docker
ensure_wise_eat_infra_network

[[ -f "${REDIS_ENV}" ]] || die ".env.redis absent — sudo ./install.sh redis (ou migrate-redis-k8s) d’abord"

# Générer mot de passe basic auth nginx si manquant
if [[ -z "${REDIS_ADMIN_BASIC_AUTH_PASSWORD:-}" ]]; then
  existing="$(read_env_var_from_file "${REDIS_ENV}" REDIS_ADMIN_BASIC_AUTH_PASSWORD || true)"
  if [[ -z "${existing}" ]]; then
    REDIS_ADMIN_BASIC_AUTH_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    {
      echo ""
      echo "# RedisInsight — https://${REDIS_ADMIN_DOMAIN}"
      echo "REDIS_ADMIN_DOMAIN=${REDIS_ADMIN_DOMAIN}"
      echo "REDIS_ADMIN_BASIC_AUTH_USER=${REDIS_ADMIN_BASIC_AUTH_USER:-redis-admin}"
      echo "REDIS_ADMIN_BASIC_AUTH_PASSWORD=${REDIS_ADMIN_BASIC_AUTH_PASSWORD}"
      echo "REDISINSIGHT_PORT=${REDIS_ADMIN_BACKEND_PORT}"
    } >> "${REDIS_ENV}"
    log "Mot de passe Redis Admin généré → ${REDIS_ENV}"
  else
    REDIS_ADMIN_BASIC_AUTH_PASSWORD="${existing}"
  fi
fi

# Clé de chiffrement RedisInsight (persistée — ne pas régénérer à chaque install)
enc_key="$(read_env_var_from_file "${REDIS_ENV}" REDISINSIGHT_ENCRYPTION_KEY || true)"
if [[ -z "${enc_key}" ]]; then
  enc_key="$(openssl rand -hex 32)"
  echo "REDISINSIGHT_ENCRYPTION_KEY=${enc_key}" >> "${REDIS_ENV}"
  log "REDISINSIGHT_ENCRYPTION_KEY générée → ${REDIS_ENV}"
fi

# URL publique pour RI_EXTERNAL_URL
if ! grep -qE '^REDIS_ADMIN_PUBLIC_URL=' "${REDIS_ENV}" 2>/dev/null; then
  echo "REDIS_ADMIN_PUBLIC_URL=https://${REDIS_ADMIN_DOMAIN}" >> "${REDIS_ENV}"
fi

set -a && source "${REDIS_ENV}" && set +a
REDIS_ADMIN_DOMAIN="${REDIS_ADMIN_DOMAIN:-redis.wise-eat.com}"
REDIS_ADMIN_BACKEND_PORT="${REDISINSIGHT_PORT:-${REDIS_ADMIN_BACKEND_PORT}}"
REDIS_ADMIN_PUBLIC_URL="${REDIS_ADMIN_PUBLIC_URL:-https://${REDIS_ADMIN_DOMAIN}}"
export REDIS_ADMIN_PUBLIC_URL CACHE_REDIS_PASSWORD BULL_REDIS_PASSWORD \
  REDISINSIGHT_ENCRYPTION_KEY REDISINSIGHT_PORT REDISINSIGHT_DATA \
  REDISINSIGHT_MEM_LIMIT REDISINSIGHT_MEMSWAP_LIMIT

[[ -n "${CACHE_REDIS_PASSWORD:-}" ]] || die "CACHE_REDIS_PASSWORD vide dans ${REDIS_ENV}"
[[ -n "${BULL_REDIS_PASSWORD:-}" ]] || die "BULL_REDIS_PASSWORD vide dans ${REDIS_ENV}"

# UID 1000 (user RedisInsight) doit pouvoir écrire /data
mkdir -p "${REDISINSIGHT_DATA:-./data-redisinsight}"
chown -R 1000:1000 "${REDISINSIGHT_DATA:-./data-redisinsight}" 2>/dev/null || true

log "Démarrage RedisInsight (127.0.0.1:${REDIS_ADMIN_BACKEND_PORT})"
docker compose -f docker-compose.redisinsight.yml --env-file .env.redis up -d --force-recreate

log "Attente RedisInsight (max 90s)…"
ok=0
for _ in $(seq 1 45); do
  code="$(curl -sf -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${REDIS_ADMIN_BACKEND_PORT}/api/health/" 2>/dev/null || echo 000)"
  if [[ "${code}" =~ ^(200|204)$ ]]; then
    ok=1
    break
  fi
  sleep 2
done
if [[ "${ok}" -ne 1 ]]; then
  warn "RedisInsight health KO — logs :"
  docker logs --tail=40 wise-eat-redisinsight 2>&1 | sed 's/^/[wise-eat]   /' || true
  die "Échec démarrage RedisInsight"
fi
log "OK  RedisInsight sur :${REDIS_ADMIN_BACKEND_PORT}"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_redis_admin_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${REDIS_ADMIN_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${REDIS_ADMIN_DOMAIN}"

render_redis_admin_site() {
  local template="$1"
  export REDIS_ADMIN_DOMAIN REDIS_ADMIN_BACKEND_HOST REDIS_ADMIN_BACKEND_PORT \
    CERTBOT_WEBROOT REDIS_ADMIN_HTASSWD_FILE
  envsubst '${REDIS_ADMIN_DOMAIN} ${REDIS_ADMIN_BACKEND_HOST} ${REDIS_ADMIN_BACKEND_PORT} ${CERTBOT_WEBROOT} ${REDIS_ADMIN_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${REDIS_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_redis_admin_site "${NGINX_CONF_SRC}/redis.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS Redis Admin (${REDIS_ADMIN_DOMAIN})"
else
  render_redis_admin_site "${NGINX_CONF_SRC}/redis.wise-eat.com.http.conf.template"
  log "Config nginx HTTP Redis Admin → ${REDIS_ADMIN_BACKEND_HOST}:${REDIS_ADMIN_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx_test_and_reload

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${REDIS_ADMIN_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${REDIS_ADMIN_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${REDIS_ADMIN_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-redis-admin-ssl.sh"
fi

log "Redis Admin public : https://${REDIS_ADMIN_DOMAIN}"
log "  Basic auth nginx : ${REDIS_ADMIN_BASIC_AUTH_USER:-redis-admin}"
log "    Mot de passe : REDIS_ADMIN_BASIC_AUTH_PASSWORD dans ${REDIS_ENV}"
log "  Connexions préconfigurées : cache (:6379) + bullmq (:6380) via host.docker.internal"
