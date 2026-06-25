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
MEMCACHED_STUNNEL_CONF_SRC="${INFRA_ROOT}/memcached/stunnel"
NGINX_CONF_SRC="${INFRA_ROOT}/nginx"
APACHE_CONF_SRC="${INFRA_ROOT}/apache"

WISE_EAT_DOMAIN="${WISE_EAT_DOMAIN:-wise-eat.cloud}"
REDIS_TLS_DOMAIN="${REDIS_TLS_DOMAIN:-cache.wise-eat.com}"
MEMCACHED_TLS_PORT="${MEMCACHED_TLS_PORT:-11212}"
GRAFANA_CONSOLE_DOMAIN="${GRAFANA_CONSOLE_DOMAIN:-console.wise-eat.com}"
GRAFANA_BACKEND_HOST="${GRAFANA_BACKEND_HOST:-127.0.0.1}"
GRAFANA_BACKEND_PORT="${GRAFANA_BACKEND_PORT:-3000}"
PROMETHEUS_LOGS_DOMAIN="${PROMETHEUS_LOGS_DOMAIN:-logs.wise-eat.com}"
PROMETHEUS_BACKEND_HOST="${PROMETHEUS_BACKEND_HOST:-127.0.0.1}"
PROMETHEUS_BACKEND_PORT="${PROMETHEUS_BACKEND_PORT:-9090}"
PROMETHEUS_BASIC_AUTH_USER="${PROMETHEUS_BASIC_AUTH_USER:-prometheus}"
PROMETHEUS_HTASSWD_FILE="${PROMETHEUS_HTASSWD_FILE:-/etc/nginx/htpasswd/prometheus-logs}"
MINIO_STORAGE_DOMAIN="${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
MINIO_BACKEND_HOST="${MINIO_BACKEND_HOST:-127.0.0.1}"
MINIO_BACKEND_PORT="${MINIO_BACKEND_PORT:-9000}"
MINIO_CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
MINIO_CONSOLE_BACKEND_HOST="${MINIO_CONSOLE_BACKEND_HOST:-127.0.0.1}"
MINIO_CONSOLE_BACKEND_PORT="${MINIO_CONSOLE_BACKEND_PORT:-9001}"
MINIO_CONSOLE_BASIC_AUTH_USER="${MINIO_CONSOLE_BASIC_AUTH_USER:-minio-console}"
MINIO_CONSOLE_HTASSWD_FILE="${MINIO_CONSOLE_HTASSWD_FILE:-/etc/nginx/htpasswd/minio-console}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}"
MINIO_STORAGE_GB="${MINIO_STORAGE_GB:-25}"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio}"
# Hostname présenté par Stunnel (:6381/:6382) — doit correspondre aux apps (REDIS_HOST).
STUNNEL_TLS_DOMAIN="${STUNNEL_TLS_DOMAIN:-${REDIS_TLS_DOMAIN}}"
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
  export WISE_EAT_DOMAIN WS_BACKEND_HOST WS_BACKEND_PORT CERTBOT_WEBROOT
  envsubst '${WISE_EAT_DOMAIN} ${WS_BACKEND_HOST} ${WS_BACKEND_PORT} ${CERTBOT_WEBROOT}' \
    < "${src}" > "${dst}"
}

# Fichiers TLS nginx requis par les templates HTTPS (certbot certonly ne les crée pas).
ensure_letsencrypt_nginx_tls_files() {
  apt install -y gettext-base certbot openssl 2>/dev/null || true
  if [[ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]]; then
    mkdir -p /etc/letsencrypt
    if [[ -f "${NGINX_CONF_SRC}/options-ssl-nginx.conf" ]]; then
      cp "${NGINX_CONF_SRC}/options-ssl-nginx.conf" /etc/letsencrypt/options-ssl-nginx.conf
    else
      curl -fsSL \
        https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
        -o /etc/letsencrypt/options-ssl-nginx.conf || \
        die "options-ssl-nginx.conf introuvable — lancer certbot install --nginx ou copier le fichier"
    fi
  fi
  if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null || \
      die "Impossible de générer /etc/letsencrypt/ssl-dhparams.pem"
  fi
}

# Basic auth nginx pour Prometheus public (logs.wise-eat.com).
ensure_prometheus_basic_auth_file() {
  local user="${PROMETHEUS_BASIC_AUTH_USER:-prometheus}"
  local pass="${PROMETHEUS_BASIC_AUTH_PASSWORD:-}"
  local file="${PROMETHEUS_HTASSWD_FILE}"

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "PROMETHEUS_BASIC_AUTH_PASSWORD requis (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth Prometheus : ${user} → ${file}"
  fi
}

# Basic auth nginx pour MinIO Console public (cdn.wise-eat.com).
ensure_minio_console_basic_auth_file() {
  local user="${MINIO_CONSOLE_BASIC_AUTH_USER:-minio-console}"
  local pass="${MINIO_CONSOLE_BASIC_AUTH_PASSWORD:-}"
  local file="${MINIO_CONSOLE_HTASSWD_FILE}"

  if [[ -z "${pass}" ]] && [[ -f "${MINIO_ENV}" ]]; then
    pass="$(read_env_var_from_file "${MINIO_ENV}" MINIO_CONSOLE_BASIC_AUTH_PASSWORD || true)"
  fi

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "MINIO_CONSOLE_BASIC_AUTH_PASSWORD requis dans ${MINIO_ENV} (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth MinIO Console : ${user} → ${file}"
  fi
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
      --exclude 'data-cache-replica/' --exclude 'data-bullmq-replica/' \
      --exclude 'data-cache-replica-1/' --exclude 'data-cache-replica-2/' \
      --exclude 'data-bullmq-replica-1/' --exclude 'data-bullmq-replica-2/' \
      --exclude 'minio/data/' --exclude 'data/' \
      --exclude 'cache-users.acl' --exclude 'bull-users.acl' \
      --exclude 'cache-replica.generated.conf' --exclude 'bull-replica.generated.conf' \
      --exclude 'cache-replica-1.generated.conf' --exclude 'cache-replica-2.generated.conf' \
      --exclude 'bull-replica-1.generated.conf' --exclude 'bull-replica-2.generated.conf' \
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

# Réseau partagé Redis / Memcached / exporters (évite host.docker.internal → 127.0.0.1 injoignable).
ensure_wise_eat_infra_network() {
  if docker network inspect wise-eat-infra >/dev/null 2>&1; then
    return 0
  fi
  docker network create wise-eat-infra >/dev/null
  log "Réseau Docker wise-eat-infra créé"
}

wait_for_container_running() {
  local name="$1"
  local max="${2:-45}"
  for _ in $(seq 1 "$max"); do
    if docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      local status
      status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo dead)"
      if [[ "${status}" == "running" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_for_prometheus_ready() {
  local max="${1:-45}"
  for _ in $(seq 1 "$max"); do
    if curl -sf 'http://127.0.0.1:9090/-/ready' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_minio_local() {
  local port="${1:-9000}"
  local max="${2:-45}"
  for _ in $(seq 1 "$max"); do
    if curl -sf "http://127.0.0.1:${port}/minio/health/live" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_minio_on_wise_eat_infra() {
  ensure_wise_eat_infra_network
  if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-minio'; then
    return 1
  fi
  if docker inspect wise-eat-minio --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
    | grep -q 'wise-eat-infra'; then
    return 0
  fi
  log "Connexion wise-eat-minio → réseau wise-eat-infra"
  docker network connect wise-eat-infra wise-eat-minio
}

_infra_minio_curl() {
  local url="$1"
  shift
  docker run --rm --network wise-eat-infra curlimages/curl:8.5.0 \
    "$@" --max-time 15 "${url}" 2>/dev/null
}

_minio_infra_ip() {
  docker inspect -f \
    '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "wise-eat-infra"}}{{$v.IPAddress}}{{end}}{{end}}' \
    wise-eat-minio 2>/dev/null || true
}

probe_minio_from_infra_network() {
  local url body ip

  for url in \
    'http://wise-eat-minio:9000/minio/health/live' \
    'http://minio:9000/minio/health/live'; do
    if _infra_minio_curl "${url}" -sf >/dev/null; then
      break
    fi
    url=""
  done
  if [[ -z "${url}" ]]; then
    ip="$(_minio_infra_ip)"
    [[ -n "${ip}" ]] || return 1
    _infra_minio_curl "http://${ip}:9000/minio/health/live" -sf >/dev/null || return 1
  fi

  body="$(_infra_minio_curl 'http://wise-eat-minio:9000/minio/v2/metrics/cluster' -sf || true)"
  if [[ -z "${body}" ]]; then
    ip="$(_minio_infra_ip)"
    [[ -n "${ip}" ]] || return 1
    body="$(_infra_minio_curl "http://${ip}:9000/minio/v2/metrics/cluster" -sf || true)"
  fi
  [[ -n "${body}" ]] && printf '%s\n' "${body}" | grep -qE '(^|\n)minio_'
}

diagnose_minio_infra_probe() {
  local url code ip
  warn "Diagnostic réseau wise-eat-infra → MinIO :"
  for url in \
    'http://wise-eat-minio:9000/minio/health/live' \
    'http://minio:9000/minio/health/live' \
    'http://wise-eat-minio:9000/minio/v2/metrics/cluster'; do
    code="$(_infra_minio_curl "${url}" -s -o /dev/null -w '%{http_code}' || echo err)"
    warn "  curl ${url} → HTTP ${code}"
  done
  ip="$(_minio_infra_ip)"
  if [[ -n "${ip}" ]]; then
    code="$(_infra_minio_curl "http://${ip}:9000/minio/v2/metrics/cluster" -s -o /dev/null -w '%{http_code}' || echo err)"
    warn "  curl http://${ip}:9000/minio/v2/metrics/cluster → HTTP ${code}"
  fi
  if wait_for_container_running wise-eat-prometheus 3; then
    if docker exec wise-eat-prometheus wget -qO- -T 8 \
      'http://wise-eat-minio:9000/minio/health/live' >/dev/null 2>&1; then
      warn "  wise-eat-prometheus → wise-eat-minio:9000 health/live : OK"
    else
      warn "  wise-eat-prometheus → wise-eat-minio:9000 health/live : FAIL"
    fi
  fi
}

prometheus_minio_scrape_up() {
  local out
  out="$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=up{job=~"minio-cluster|minio-node|minio"}' 2>/dev/null || true)"
  [[ -n "${out}" ]] && printf '%s' "${out}" | grep -qE '"value"\s*:\s*\[[^]]+,\s*"1"\]'
}

env_truthy() {
  local raw="${1:-}"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]')"
  [[ "${raw}" == "1" || "${raw}" == "true" || "${raw}" == "yes" || "${raw}" == "on" ]]
}

read_env_var_from_file() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 1
  local line
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 1
  echo "${line#*=}"
}

redis_cluster_b_enabled() {
  local raw
  raw="$(read_env_var_from_file "${REDIS_ENV}" REDIS_CLUSTER_B_ENABLED || true)"
  [[ -z "${raw}" ]] && raw="true"
  env_truthy "${raw}"
}

memcached_cluster_b_enabled() {
  local file="${MEMCACHED_DIR}/.env.memcached"
  local raw
  raw="$(read_env_var_from_file "${file}" MEMCACHED_CLUSTER_B_ENABLED || true)"
  [[ -z "${raw}" ]] && raw="true"
  env_truthy "${raw}"
}

# Anciens exporters réplicas (1 seul conteneur / suffixe -b) — bloquent :9123/:9124/:9151.
remove_legacy_monitoring_exporter_containers() {
  local legacy=(
    wise-eat-redis-exporter-cache-replica
    wise-eat-redis-exporter-bullmq-replica
    wise-eat-memcached-exporter-b
    wise-eat-memcached-exporter-replica
  )
  local name removed=0
  for name in "${legacy[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
      warn "Suppression conteneur monitoring obsolète : ${name}"
      docker rm -f "${name}" >/dev/null
      removed=1
    fi
  done
  if [[ "${removed}" -eq 1 ]]; then
    log "Exporters legacy supprimés — relance compose avec --remove-orphans"
  fi
}

wise_eat_compose_profiles() {
  local profiles=()
  if redis_cluster_b_enabled; then
    profiles+=(cluster-b)
  fi
  if memcached_cluster_b_enabled; then
    profiles+=(cluster-b)
  fi
  if [[ "${#profiles[@]}" -eq 0 ]]; then
    return 0
  fi
  # Déduplique cluster-b
  echo "cluster-b"
}
