#!/usr/bin/env bash
# Chemins et helpers partagés — Wise Eat infra VPS.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WISE_EAT_ROOT="${WISE_EAT_ROOT:-${INFRA_ROOT}}"
REDIS_DIR="${REDIS_DIR:-${WISE_EAT_ROOT}/redis}"
MEMCACHED_DIR="${MEMCACHED_DIR:-${WISE_EAT_ROOT}/memcached}"
MINIO_DIR="${MINIO_DIR:-${WISE_EAT_ROOT}/minio}"
MON_DIR="${MON_DIR:-${WISE_EAT_ROOT}/monitoring}"
REDIS_ENV="${REDIS_ENV:-${REDIS_DIR}/.env.redis}"
MINIO_ENV="${MINIO_ENV:-${MINIO_DIR}/.env.minio}"
STUNNEL_CONF_SRC="${INFRA_ROOT}/redis/stunnel"
NGINX_CONF_SRC="${INFRA_ROOT}/nginx"
APACHE_CONF_SRC="${INFRA_ROOT}/apache"

WISE_EAT_DOMAIN="${WISE_EAT_DOMAIN:-wise-eat.cloud}"
STUNNEL_TLS_DOMAIN="${STUNNEL_TLS_DOMAIN:-${WISE_EAT_DOMAIN}}"
WS_BACKEND_HOST="${WS_BACKEND_HOST:-127.0.0.1}"
WS_BACKEND_PORT="${WS_BACKEND_PORT:-8000}"
CERTBOT_WEBROOT="${CERTBOT_WEBROOT:-/var/www/certbot}"

stop_conflicting_webserver() {
  local keep="$1"
  if [[ "${keep}" != "nginx" ]] && systemctl is-active nginx >/dev/null 2>&1; then
    warn "Arrêt nginx (seul un serveur web doit écouter sur :80)"
    systemctl stop nginx
    systemctl disable nginx 2>/dev/null || true
  fi
  if [[ "${keep}" != "apache" ]] && systemctl is-active apache2 >/dev/null 2>&1; then
    warn "Arrêt apache2 (seul un serveur web doit écouter sur :80)"
    systemctl stop apache2
    systemctl disable apache2 2>/dev/null || true
  fi
}

render_template() {
  local src="$1" dst="$2"
  WISE_EAT_DOMAIN WS_BACKEND_HOST WS_BACKEND_PORT CERTBOT_WEBROOT \
    envsubst '${WISE_EAT_DOMAIN} ${WS_BACKEND_HOST} ${WS_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${src}" > "${dst}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Exécuter en root : sudo $0 $*" >&2
    exit 1
  fi
}

log() { echo "[wise-eat] $*"; }
warn() { echo "[wise-eat] WARN: $*" >&2; }
die() { echo "[wise-eat] ERROR: $*" >&2; exit 1; }

sync_component() {
  local name="$1"
  local src="${INFRA_ROOT}/${name}"
  local dst="${WISE_EAT_ROOT}/${name}"
  [[ -d "${src}" ]] || die "Composant introuvable : ${src}"
  if [[ "${src}" != "${dst}" ]]; then
    log "Sync ${name} → ${dst}"
    mkdir -p "${dst}"
    rsync -a --exclude '.env.redis' --exclude '.env.monitoring' \
      --exclude '.env.memcached' --exclude '.env.minio' \
      --exclude 'data-cache/' --exclude 'data-bullmq/' \
      --exclude 'minio/data/' --exclude 'data/' \
      --exclude 'cache-users.acl' --exclude 'bull-users.acl' \
      "${src}/" "${dst}/"
  fi
}

stop_valkey_if_present() {
  systemctl stop valkey-server valkey redis-server 2>/dev/null || true
  systemctl disable valkey-server valkey redis-server 2>/dev/null || true
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker requis — apt install docker-ce"
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin requis"
}
