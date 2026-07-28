#!/usr/bin/env bash
# Reverse-proxy nginx → MinIO Console (cdn.wise-eat.com) + basic auth + Certbot optionnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

MINIO_CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
MINIO_CONSOLE_BACKEND_HOST="${MINIO_CONSOLE_BACKEND_HOST:-127.0.0.1}"
MINIO_CONSOLE_BACKEND_PORT="${MINIO_CONSOLE_BACKEND_PORT:-9001}"
STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}"

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
fi

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"

ensure_minio_console_basic_auth_file

mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${CERTBOT_WEBROOT}" 2>/dev/null || true

SITE="/etc/nginx/sites-available/${MINIO_CONSOLE_DOMAIN}"
ENABLED="/etc/nginx/sites-enabled/${MINIO_CONSOLE_DOMAIN}"

render_minio_console_site() {
  local template="$1"
  export MINIO_CONSOLE_DOMAIN MINIO_CONSOLE_BACKEND_HOST MINIO_CONSOLE_BACKEND_PORT \
    CERTBOT_WEBROOT MINIO_CONSOLE_HTASSWD_FILE
  envsubst '${MINIO_CONSOLE_DOMAIN} ${MINIO_CONSOLE_BACKEND_HOST} ${MINIO_CONSOLE_BACKEND_PORT} ${CERTBOT_WEBROOT} ${MINIO_CONSOLE_HTASSWD_FILE}' \
    < "${template}" > "${SITE}"
}

if [[ -f "/etc/letsencrypt/live/${MINIO_CONSOLE_DOMAIN}/fullchain.pem" ]]; then
  ensure_letsencrypt_nginx_tls_files
  render_minio_console_site "${NGINX_CONF_SRC}/cdn.wise-eat.com.https.conf.template"
  log "Config nginx HTTPS MinIO Console (${MINIO_CONSOLE_DOMAIN})"
else
  render_minio_console_site "${NGINX_CONF_SRC}/cdn.wise-eat.com.http.conf.template"
  log "Config nginx HTTP MinIO Console → ${MINIO_CONSOLE_BACKEND_HOST}:${MINIO_CONSOLE_BACKEND_PORT}"
fi

ln -sf "${SITE}" "${ENABLED}"
nginx -t
systemctl reload nginx

if [[ -n "${STUNNEL_TLS_EMAIL}" ]] && [[ ! -f "/etc/letsencrypt/live/${MINIO_CONSOLE_DOMAIN}/fullchain.pem" ]]; then
  log "Certbot pour ${MINIO_CONSOLE_DOMAIN}…"
  apt install -y certbot 2>/dev/null || true
  certbot certonly --webroot \
    -w "${CERTBOT_WEBROOT}" \
    -d "${MINIO_CONSOLE_DOMAIN}" \
    --email "${STUNNEL_TLS_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
  bash "${SCRIPT_DIR}/enable-minio-console-ssl.sh"
fi

log "MinIO Console public : https://${MINIO_CONSOLE_DOMAIN}"
log "  Couche 1 : basic auth nginx (${MINIO_CONSOLE_BASIC_AUTH_USER:-minio-console})"
log "    Mot de passe : MINIO_CONSOLE_BASIC_AUTH_PASSWORD dans ${MINIO_ENV}"
log "    (≠ MINIO_ROOT_USER / MINIO_ROOT_PASSWORD — identifiants MinIO après la popup)"
log "  Couche 2 : identifiants MinIO (MINIO_ROOT_USER dans .env.minio)"

# Appliquer MINIO_BROWSER_REDIRECT_URL : pods K8s (post-migration) ou Docker legacy.
minio_k8s=false
if command -v kubectl >/dev/null 2>&1 || command -v k3s >/dev/null 2>&1; then
  _kubectl=(kubectl)
  if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    _kubectl=(sudo k3s kubectl)
  fi
  if "${_kubectl[@]}" -n wise-eat get deploy/minio >/dev/null 2>&1; then
    ready="$("${_kubectl[@]}" -n wise-eat get deploy/minio -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready}" == "1" ]] && minio_k8s=true
  fi
fi

if [[ "${minio_k8s}" == "true" ]]; then
  # Secret K8s porte MINIO_BROWSER_REDIRECT_URL=https://cdn.wise-eat.com (login console).
  log "MinIO K8s — sync secret + rollout (MINIO_BROWSER_REDIRECT_URL → cdn)"
  bash "${INFRA_ROOT}/k8s/scripts/create-minio-secret.sh"
  "${_kubectl[@]}" -n wise-eat rollout restart deploy/minio
  "${_kubectl[@]}" -n wise-eat rollout status deploy/minio --timeout=120s || \
    warn "Rollout minio non terminé — vérifier console :9001"
  # Console doit répondre sur hostPort 9001 (nginx cdn.wise-eat.com).
  if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MINIO_CONSOLE_BACKEND_PORT}/" \
    | grep -qE '^(200|204|301|302|307|401|403)$'; then
    log "Console locale OK :${MINIO_CONSOLE_BACKEND_PORT}"
  else
    warn "Console :${MINIO_CONSOLE_BACKEND_PORT} non joignable — sudo ./scripts/verify-minio-ops.sh"
  fi
elif [[ -f "${MINIO_ENV}" ]] && docker ps --format '{{.Names}}' | grep -q '^wise-eat-minio$'; then
  log "Recréation conteneur MinIO Docker (MINIO_BROWSER_REDIRECT_URL)…"
  cd "${MINIO_DIR}"
  docker compose --env-file .env.minio up -d --force-recreate minio
fi
