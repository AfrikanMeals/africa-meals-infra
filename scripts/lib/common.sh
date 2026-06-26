#!/usr/bin/env bash
# Chemins et helpers partagés — Wise Eat infra VPS.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WISE_EAT_ROOT="${WISE_EAT_ROOT:-${INFRA_ROOT}}"
REDIS_DIR="${REDIS_DIR:-${WISE_EAT_ROOT}/redis}"
MEMCACHED_DIR="${MEMCACHED_DIR:-${WISE_EAT_ROOT}/memcached}"
MINIO_DIR="${MINIO_DIR:-${WISE_EAT_ROOT}/minio}"
EMQX_DIR="${EMQX_DIR:-${WISE_EAT_ROOT}/emqx}"
MONGODB_DIR="${MONGODB_DIR:-${WISE_EAT_ROOT}/mongodb}"
OLLAMA_DIR="${OLLAMA_DIR:-${WISE_EAT_ROOT}/ollama}"
MON_DIR="${MON_DIR:-${WISE_EAT_ROOT}/monitoring}"
REDIS_ENV="${REDIS_ENV:-${REDIS_DIR}/.env.redis}"
MINIO_ENV="${MINIO_ENV:-${MINIO_DIR}/.env.minio}"
EMQX_ENV="${EMQX_ENV:-${EMQX_DIR}/.env.emqx}"
MONGODB_ENV="${MONGODB_ENV:-${MONGODB_DIR}/.env.mongodb}"
EMQX_BROKER_DOMAIN="${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}"
EMQX_BACKEND_HOST="${EMQX_BACKEND_HOST:-127.0.0.1}"
EMQX_MQTTS_PORT="${EMQX_MQTTS_PORT:-8883}"
EMQX_WSS_PORT="${EMQX_WSS_PORT:-8884}"
EMQX_WORKER_DOMAIN="${EMQX_WORKER_DOMAIN:-worker.wise-eat.com}"
EMQX_DASHBOARD_BACKEND_HOST="${EMQX_DASHBOARD_BACKEND_HOST:-127.0.0.1}"
EMQX_DASHBOARD_BACKEND_PORT="${EMQX_DASHBOARD_BACKEND_PORT:-18083}"
EMQX_WORKER_BASIC_AUTH_USER="${EMQX_WORKER_BASIC_AUTH_USER:-emqx-worker}"
EMQX_WORKER_HTASSWD_FILE="${EMQX_WORKER_HTASSWD_FILE:-/etc/nginx/htpasswd/emqx-worker}"
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
MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"
MONGO_ADMIN_DOMAIN="${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
MONGO_ADMIN_BACKEND_HOST="${MONGO_ADMIN_BACKEND_HOST:-127.0.0.1}"
MONGO_ADMIN_BACKEND_PORT="${MONGO_ADMIN_BACKEND_PORT:-8081}"
MONGO_ADMIN_BASIC_AUTH_USER="${MONGO_ADMIN_BASIC_AUTH_USER:-mongo-admin}"
MONGO_ADMIN_HTASSWD_FILE="${MONGO_ADMIN_HTASSWD_FILE:-/etc/nginx/htpasswd/mongo-admin}"
MONGO_DATA_DIR="${MONGO_DATA_DIR:-/var/lib/wise-eat/mongodb}"
MONGO_STORAGE_GB="${MONGO_STORAGE_GB:-5}"
MONGO_BACKUP_DIR="${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}"
OLLAMA_GATEWAY_DOMAIN="${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}"
OLLAMA_BACKEND_HOST="${OLLAMA_BACKEND_HOST:-127.0.0.1}"
OLLAMA_BACKEND_PORT="${OLLAMA_BACKEND_PORT:-11434}"
OLLAMA_GATEWAY_BASIC_AUTH_USER="${OLLAMA_GATEWAY_BASIC_AUTH_USER:-ollama}"
OLLAMA_GATEWAY_HTASSWD_FILE="${OLLAMA_GATEWAY_HTASSWD_FILE:-/etc/nginx/htpasswd/ollama-gateway}"
# Hostname présenté par Stunnel (:6381/:6382) — doit correspondre aux apps (REDIS_HOST).
STUNNEL_TLS_DOMAIN="${STUNNEL_TLS_DOMAIN:-${REDIS_TLS_DOMAIN}}"
# IPv6 publique VPS (enregistrements AAAA Cloudflare — Hostinger).
VPS_IPV6_ADDR="${VPS_IPV6_ADDR:-2a02:4780:75:447e::1}"
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
  if [[ -f "${NGINX_CONF_SRC}/options-ssl-nginx-stream.conf" ]] \
    && [[ ! -f /etc/letsencrypt/options-ssl-nginx-stream.conf ]]; then
    cp "${NGINX_CONF_SRC}/options-ssl-nginx-stream.conf" /etc/letsencrypt/options-ssl-nginx-stream.conf
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

# Basic auth nginx pour Ollama public (ai.wise-eat.com).
ensure_ollama_gateway_basic_auth_file() {
  local user="${OLLAMA_GATEWAY_BASIC_AUTH_USER:-ollama}"
  local pass="${OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD:-}"
  local file="${OLLAMA_GATEWAY_HTASSWD_FILE}"

  if [[ -f "${OLLAMA_DIR}/.env.ollama" ]]; then
    set -a && source "${OLLAMA_DIR}/.env.ollama" && set +a
    user="${OLLAMA_GATEWAY_BASIC_AUTH_USER:-ollama}"
    pass="${OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD:-}"
  fi

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "OLLAMA_GATEWAY_BASIC_AUTH_PASSWORD requis (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth Ollama : ${user} → ${file}"
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
    log "Basic auth MinIO Console : ${user} → ${file} (mot de passe resynchronisé depuis .env.minio)"
  elif [[ -f "${file}" ]]; then
    log "Basic auth MinIO Console : ${file} (inchangé — définir MINIO_CONSOLE_BASIC_AUTH_PASSWORD pour forcer)"
  fi
}

# Basic auth nginx pour MongoDB Admin public (data.wise-eat.com).
ensure_mongodb_admin_basic_auth_file() {
  local user="${MONGO_ADMIN_BASIC_AUTH_USER:-mongo-admin}"
  local pass="${MONGO_ADMIN_BASIC_AUTH_PASSWORD:-}"
  local file="${MONGO_ADMIN_HTASSWD_FILE}"

  if [[ -z "${pass}" ]] && [[ -f "${MONGODB_ENV}" ]]; then
    pass="$(read_env_var_from_file "${MONGODB_ENV}" MONGO_ADMIN_BASIC_AUTH_PASSWORD || true)"
  fi

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "MONGO_ADMIN_BASIC_AUTH_PASSWORD requis dans ${MONGODB_ENV} (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth MongoDB Admin : ${user} → ${file}"
  elif [[ -f "${file}" ]]; then
    log "Basic auth MongoDB Admin : ${file} (inchangé)"
  fi
}

# Basic auth nginx pour EMQX Dashboard public (worker.wise-eat.com).
ensure_emqx_worker_basic_auth_file() {
  local user="${EMQX_WORKER_BASIC_AUTH_USER:-emqx-worker}"
  local pass="${EMQX_WORKER_BASIC_AUTH_PASSWORD:-}"
  local file="${EMQX_WORKER_HTASSWD_FILE}"

  if [[ -z "${pass}" ]] && [[ -f "${EMQX_ENV}" ]]; then
    pass="$(read_env_var_from_file "${EMQX_ENV}" EMQX_WORKER_BASIC_AUTH_PASSWORD || true)"
  fi

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "EMQX_WORKER_BASIC_AUTH_PASSWORD requis dans ${EMQX_ENV} (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth EMQX Dashboard : ${user} → ${file} (mot de passe resynchronisé depuis .env.emqx)"
  elif [[ -f "${file}" ]]; then
    log "Basic auth EMQX Dashboard : ${file} (inchangé — définir EMQX_WORKER_BASIC_AUTH_PASSWORD pour forcer)"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Exécuter en root : sudo $0 $*" >&2
    exit 1
  fi
}

# UFW doit gérer IPv6 (sinon les règles n’ouvrent que v4 malgré les AAAA DNS).
ensure_ufw_ipv6_enabled() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  local ufw_default="/etc/default/ufw"
  [[ -f "${ufw_default}" ]] || return 0
  if grep -q '^IPV6=no' "${ufw_default}" 2>/dev/null; then
    log "Activation UFW IPv6 (IPV6=yes dans ${ufw_default})"
    sed -i 's/^IPV6=no/IPV6=yes/' "${ufw_default}"
  elif ! grep -q '^IPV6=' "${ufw_default}" 2>/dev/null; then
    log "Ajout IPV6=yes dans ${ufw_default}"
    printf '\nIPV6=yes\n' >> "${ufw_default}"
  fi
}

ufw_allow_tcp_port() {
  local port="$1"
  local comment="$2"
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  ufw allow "${port}"/tcp comment "${comment}" 2>/dev/null || true
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
      --exclude '.env.memcached' --exclude '.env.minio' --exclude '.env.emqx' \
      --exclude '.env.mongodb' --exclude '.env.ollama' \
      --exclude 'data-cache/' --exclude 'data-bullmq/' \
      --exclude 'data-cache-replica/' --exclude 'data-bullmq-replica/' \
      --exclude 'data-cache-replica-1/' --exclude 'data-cache-replica-2/' \
      --exclude 'data-bullmq-replica-1/' --exclude 'data-bullmq-replica-2/' \
      --exclude 'data-emqx-1/' --exclude 'data-emqx-2/' --exclude 'data-emqx-3/' \
      --exclude 'data-mongo-1/' --exclude 'data-mongo-2/' --exclude 'data-mongo-3/' \
      --exclude 'data-dbgate/' \
      --exclude 'keyfile' \
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

ensure_ollama_on_wise_eat_infra() {
  ensure_wise_eat_infra_network
  if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-ollama'; then
    return 1
  fi
  if docker inspect wise-eat-ollama --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
    | grep -q 'wise-eat-infra'; then
    return 0
  fi
  log "Connexion wise-eat-ollama → réseau wise-eat-infra"
  docker network connect wise-eat-infra wise-eat-ollama
}

wait_for_ollama_api() {
  local max="${1:-60}"
  local port="${OLLAMA_BACKEND_PORT:-11434}"
  for _ in $(seq 1 "$max"); do
    if curl -sf "http://127.0.0.1:${port}/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

refresh_cadvisor_if_present() {
  if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-cadvisor'; then
    log "Redémarrage cAdvisor (prise en compte du conteneur Ollama)…"
    docker restart wise-eat-cadvisor >/dev/null
    sleep 6
  fi
}

verify_cadvisor_ollama_metrics() {
  local max="${1:-30}"
  local i
  for i in $(seq 1 "$max"); do
    if curl -sf http://127.0.0.1:8088/metrics 2>/dev/null | grep -Eq \
      'container_label_com_wise_eat_service="ollama"|wise-eat-ollama|ollama/ollama'; then
      log "cAdvisor remonte le conteneur Ollama (tentative ${i}/${max})"
      return 0
    fi
    if [[ "$i" -lt 6 ]]; then
      refresh_cadvisor_if_present
    fi
    sleep 2
  done
  warn "cAdvisor ne remonte pas encore Ollama — recréer le conteneur puis : sudo ./install.sh repair-ollama-monitoring"
  return 1
}

ensure_mongodb_on_wise_eat_infra() {
  ensure_wise_eat_infra_network
  local name
  for name in wise-eat-mongo-1 wise-eat-mongo-2 wise-eat-mongo-3 wise-eat-dbgate wise-eat-mongodb-exporter; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      continue
    fi
    if docker inspect "${name}" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
      | grep -q 'wise-eat-infra'; then
      continue
    fi
    log "Connexion ${name} → réseau wise-eat-infra"
    docker network connect wise-eat-infra "${name}"
  done
  if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-mongo-1'; then
    return 1
  fi
  return 0
}

ensure_emqx_on_wise_eat_infra() {
  ensure_wise_eat_infra_network
  local name connected=1
  for name in wise-eat-emqx-1 wise-eat-emqx-2 wise-eat-emqx-3; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      continue
    fi
    if docker inspect "${name}" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
      | grep -q 'wise-eat-infra'; then
      continue
    fi
    log "Connexion ${name} → réseau wise-eat-infra"
    docker network connect wise-eat-infra "${name}"
    connected=0
  done
  if ! docker ps --format '{{.Names}}' | grep -qx 'wise-eat-emqx-1'; then
    return 1
  fi
  return 0
}

# Arrête compose EMQX et supprime conteneurs orphelins (Docker Desktop / ancien projet « emqx »).
prepare_emqx_compose_stack() {
  local env_file="${1:-${EMQX_DIR}/.env.emqx}"
  local compose_args=()
  [[ -f "${env_file}" ]] && compose_args=(--env-file "${env_file}")

  log "Arrêt stack EMQX (compose wise-eat-emqx + legacy emqx)"
  if [[ -d "${EMQX_DIR}" ]]; then
    (
      cd "${EMQX_DIR}"
      docker compose "${compose_args[@]}" down --remove-orphans 2>/dev/null || true
      docker compose -p emqx "${compose_args[@]}" down --remove-orphans 2>/dev/null || true
      docker compose -p wise-eat-emqx "${compose_args[@]}" down --remove-orphans 2>/dev/null || true
    )
  fi

  local name n
  for n in 1 2 3; do
    name="wise-eat-emqx-${n}"
    if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
      warn "Suppression conteneur EMQX orphelin : ${name}"
      docker rm -f "${name}" >/dev/null
    fi
  done
}

reset_emqx_replica_data_dirs() {
  log "Réinitialisation data réplicas (data-emqx-2, data-emqx-3)"
  rm -rf "${EMQX_DIR}/data-emqx-2" "${EMQX_DIR}/data-emqx-3"
  mkdir -p "${EMQX_DIR}/data-emqx-2" "${EMQX_DIR}/data-emqx-3"
  chown -R 1000:1000 "${EMQX_DIR}/data-emqx-2" "${EMQX_DIR}/data-emqx-3"
}

reset_emqx_primary_data_dir() {
  local backup="${EMQX_DIR}/data-emqx-1.bak.$(date +%Y%m%d%H%M%S)"
  if [[ -d "${EMQX_DIR}/data-emqx-1" ]] && [[ -n "$(ls -A "${EMQX_DIR}/data-emqx-1" 2>/dev/null || true)" ]]; then
    warn "Sauvegarde primary EMQX → ${backup}"
    mv "${EMQX_DIR}/data-emqx-1" "${backup}"
  elif [[ -d "${EMQX_DIR}/data-emqx-1" ]]; then
    rm -rf "${EMQX_DIR}/data-emqx-1"
  fi
  mkdir -p "${EMQX_DIR}/data-emqx-1"
  chown -R 1000:1000 "${EMQX_DIR}/data-emqx-1"
}

check_emqx_host_ports_free() {
  local mqtt_port="${EMQX_MQTT_PORT:-1883}"
  local ws_port="${EMQX_WS_PORT:-8083}"
  local dash_port="${EMQX_DASHBOARD_PORT:-18083}"
  local port label

  for port in "${mqtt_port}" "${ws_port}" "${dash_port}"; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
      label=":${port}"
      [[ "${port}" == "${mqtt_port}" ]] && label="MQTT :${port}"
      [[ "${port}" == "${ws_port}" ]] && label="WS :${port}"
      [[ "${port}" == "${dash_port}" ]] && label="Dashboard :${port}"
      warn "Port ${label} déjà utilisé sur le VPS"
      ss -ltnp 2>/dev/null | grep ":${port} " | sed 's/^/[wise-eat]      /' || true
    fi
  done
}

emqx_api_responds() {
  local port="${1:-18083}"
  curl -sf --connect-timeout 2 --max-time 5 "http://127.0.0.1:${port}/api/v5/status" >/dev/null 2>&1 \
    || curl -sf --connect-timeout 2 --max-time 5 "http://127.0.0.1:${port}/status" >/dev/null 2>&1
}

wait_for_emqx_api() {
  local port="${1:-18083}"
  local max="${2:-45}"
  local container="${3:-wise-eat-emqx-1}"
  local state health i

  log "Attente API EMQX http://127.0.0.1:${port} (max $((max * 2))s, logs toutes les 10s)…"
  for i in $(seq 1 "$max"); do
    state="$(docker inspect "${container}" --format '{{.State.Status}}' 2>/dev/null || echo missing)"
    if [[ "${state}" == "exited" || "${state}" == "dead" || "${state}" == "missing" ]]; then
      warn "${container} indisponible (${state}) après $((i * 2))s"
      diagnose_emqx_container "${container}"
      return 1
    fi
    if emqx_api_responds "${port}"; then
      log "OK  EMQX API prête (~$((i * 2))s)"
      return 0
    fi
    if (( i % 5 == 0 )); then
      health="$(docker inspect "${container}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null || echo '?')"
      log "… attente ${i}/${max} — status=${state} health=${health}"
    fi
    sleep 2
  done
  return 1
}

diagnose_emqx_container() {
  local name="${1:-wise-eat-emqx-1}"
  warn "Diagnostic ${name} :"
  docker inspect "${name}" --format '  status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} exit={{.State.ExitCode}}' 2>/dev/null || true
  if docker inspect "${name}" --format '{{if .State.Health}}{{range .State.Health.Log}}  health: {{.ExitCode}} {{.Output}}{{end}}{{end}}' 2>/dev/null | tail -3; then
    true
  fi
  docker logs --tail=50 "${name}" 2>&1 | sed 's/^/[wise-eat]      /' || true
}

emqx_primary_ready() {
  wait_for_emqx_api "${EMQX_DASHBOARD_PORT:-18083}" 3
}

emqx_prometheus_stats_url() {
  local port="${1:-${EMQX_DASHBOARD_PORT:-18083}}"
  echo "http://127.0.0.1:${port}/api/v5/prometheus/stats"
}

emqx_fetch_prometheus_stats() {
  local port="${1:-${EMQX_DASHBOARD_PORT:-18083}}"
  curl -sf --connect-timeout 3 --max-time 15 "$(emqx_prometheus_stats_url "${port}")" 2>/dev/null || true
}

emqx_prometheus_metric_present() {
  local metric="$1" body="${2:-}"
  [[ -n "${body}" ]] || body="$(emqx_fetch_prometheus_stats)"
  [[ -n "${body}" ]] && printf '%s\n' "${body}" | grep -qE "(^|[[:space:]])${metric}([[:space:]]|$)"
}

emqx_container_has_prometheus_collector_env() {
  local container="${1:-wise-eat-emqx-1}"
  docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -qE '^EMQX_PROMETHEUS__(VM_MEMORY_COLLECTOR|COLLECTORS__VM_MEMORY)=enabled$'
}

fix_emqx_cluster_hocon_prometheus() {
  local py="${INFRA_ROOT}/scripts/fix-emqx-cluster-hocon-prometheus.py"
  local f n
  [[ -f "${py}" ]] || return 0
  for n in 1 2 3; do
    f="${EMQX_DIR}/data-emqx-${n}/configs/cluster.hocon"
    [[ -f "${f}" ]] || continue
    if grep -qE '[[:space:]]collectors[[:space:]]*\{' "${f}" 2>/dev/null; then
      log "Retrait prometheus.collectors invalide → ${f}"
      python3 "${py}" "${f}" || warn "Patch cluster.hocon échoué : ${f}"
    fi
  done
}

ensure_emqx_prometheus_collectors() {
  local force="${EMQX_FORCE_RECREATE:-0}"
  local env_file="${EMQX_DIR}/.env.emqx"
  local compose_args=(--env-file "${env_file}")

  [[ -d "${EMQX_DIR}" ]] || return 0
  [[ -f "${env_file}" ]] || die ".env.emqx absent — sudo ./install.sh emqx"

  # Anciennes vars (crash-loop schema) — recréation obligatoire après git pull.
  if docker inspect wise-eat-emqx-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -qE '^EMQX_PROMETHEUS__(ENABLE=|COLLECTORS__)'; then
    warn "Variables Prometheus obsolètes détectées — recréation EMQX"
    force=1
  fi

  if [[ "${force}" == "1" ]]; then
    log "EMQX_FORCE_RECREATE=1 — recréation stack EMQX"
  elif ! emqx_container_has_prometheus_collector_env; then
    log "Collecteurs Erlang VM / Mnesia absents du conteneur — recréation EMQX"
    force=1
  else
    log "Collecteurs Prometheus EMQX déjà configurés"
    return 0
  fi

  (
    cd "${EMQX_DIR}"
    docker compose "${compose_args[@]}" stop emqx-1 emqx-2 emqx-3 2>/dev/null || true
  )
  fix_emqx_cluster_hocon_prometheus

  (
    cd "${EMQX_DIR}"
    docker compose "${compose_args[@]}" up -d --force-recreate
  )

  ensure_emqx_on_wise_eat_infra || true
  wait_for_emqx_api "${EMQX_DASHBOARD_PORT:-18083}" 90 \
    || die "EMQX API injoignable après mise à jour collecteurs — lancer : sudo ./install.sh repair-emqx-boot"
}

wait_for_emqx_prometheus_metrics() {
  local port="${1:-${EMQX_DASHBOARD_PORT:-18083}}"
  local max="${2:-36}"
  local metric body i
  shift 2 2>/dev/null || true
  local metrics=("$@")
  if [[ "${#metrics[@]}" -eq 0 ]]; then
    metrics=(erlang_vm_process_count emqx_vm_total_memory)
  fi

  log "Attente métriques Prometheus EMQX (:${port}, max $((max * 5))s)…"
  for ((i = 1; i <= max; i++)); do
    body="$(emqx_fetch_prometheus_stats "${port}")"
    if [[ -n "${body}" ]] && printf '%s\n' "${body}" | grep -q 'emqx_connections_count'; then
      local all=1 metric
      for metric in "${metrics[@]}"; do
        if ! emqx_prometheus_metric_present "${metric}" "${body}"; then
          all=0
          break
        fi
      done
      if [[ "${all}" -eq 1 ]]; then
        log "OK  métriques EMQX prêtes (~$((i * 5))s)"
        return 0
      fi
    fi
    if (( i % 6 == 0 )); then
      log "… attente métriques ${i}/${max}"
    fi
    sleep 5
  done
  return 1
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

emqx_cluster_b_enabled() {
  local raw
  raw="$(read_env_var_from_file "${EMQX_ENV}" EMQX_CLUSTER_B_ENABLED || true)"
  [[ -z "${raw}" ]] && raw="true"
  env_truthy "${raw}"
}

remove_broken_nginx_module_symlinks() {
  local f
  shopt -s nullglob
  for f in /etc/nginx/modules-enabled/*; do
    if [[ -L "${f}" ]] && [[ ! -e "${f}" ]]; then
      warn "Symlink nginx cassé supprimé : ${f}"
      rm -f "${f}"
    fi
  done
  shopt -u nullglob
}

nginx_stream_is_static() {
  nginx -V 2>&1 | grep -q 'with-stream' && ! nginx -V 2>&1 | grep -q 'with-stream=dynamic'
}

nginx_stream_needs_load_module() {
  nginx -V 2>&1 | grep -q 'with-stream=dynamic'
}

find_nginx_stream_module_so() {
  local so
  if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    echo /usr/lib/nginx/modules/ngx_stream_module.so
    return 0
  fi
  while IFS= read -r so; do
    if [[ -f "${so}" ]]; then
      echo "${so}"
      return 0
    fi
  done < <(dpkg -L libnginx-mod-stream 2>/dev/null | grep 'ngx_stream_module\.so$' || true)
  return 1
}

create_nginx_stream_module_conf_if_missing() {
  local so load_line conf="/etc/nginx/modules-available/mod-stream.conf"
  [[ -f "${conf}" ]] && return 0
  [[ -f /usr/share/nginx/modules-available/mod-stream.conf ]] && return 0

  so="$(find_nginx_stream_module_so || true)"
  [[ -n "${so}" ]] || return 1

  if [[ "${so}" == /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    load_line="load_module modules/ngx_stream_module.so;"
  else
    load_line="load_module ${so};"
  fi

  mkdir -p /etc/nginx/modules-available
  printf '%s\n' "${load_line}" > "${conf}"
  log "Création ${conf} (${load_line})"
}

enable_nginx_stream_module_conf() {
  local candidate enabled_name="/etc/nginx/modules-enabled/50-mod-stream.conf"
  for candidate in \
    /usr/share/nginx/modules-available/mod-stream.conf \
    /etc/nginx/modules-available/mod-stream.conf \
    /etc/nginx/modules-available/50-mod-stream.conf; do
    if [[ -f "${candidate}" ]]; then
      if [[ ! -e "${enabled_name}" ]] || [[ "$(readlink -f "${enabled_name}" 2>/dev/null)" != "$(readlink -f "${candidate}" 2>/dev/null)" ]]; then
        ln -sf "${candidate}" "${enabled_name}"
        log "Module stream activé : 50-mod-stream.conf → ${candidate}"
      fi
      return 0
    fi
  done

  create_nginx_stream_module_conf_if_missing || return 1
  ln -sf /etc/nginx/modules-available/mod-stream.conf "${enabled_name}"
  log "Module stream activé : 50-mod-stream.conf → /etc/nginx/modules-available/mod-stream.conf"
  return 0
}

ensure_nginx_stream_module() {
  command -v nginx >/dev/null 2>&1 || return 0

  remove_broken_nginx_module_symlinks

  if nginx_stream_is_static; then
    return 0
  fi

  if enable_nginx_stream_module_conf; then
    return 0
  fi

  log "Installation module nginx stream (libnginx-mod-stream)…"
  apt install -y libnginx-mod-stream nginx-common 2>/dev/null \
    || apt install -y libnginx-mod-stream 2>/dev/null \
    || apt install -y nginx-full 2>/dev/null || true

  if enable_nginx_stream_module_conf; then
    return 0
  fi

  apt install -y --reinstall libnginx-mod-stream 2>/dev/null || true
  enable_nginx_stream_module_conf || \
    die "Module stream introuvable — vérifier : dpkg -L libnginx-mod-stream | grep stream"
}

ensure_nginx_stream_include() {
  command -v nginx >/dev/null 2>&1 || return 0
  ensure_nginx_stream_module
  mkdir -p /etc/nginx/stream.d
  if ! grep -qF '/etc/nginx/stream.d/' /etc/nginx/nginx.conf 2>/dev/null; then
    log "Activation module stream nginx (/etc/nginx/stream.d/)"
    cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
  fi
}

nginx_test_and_reload() {
  ensure_nginx_stream_module
  if ! nginx -t 2>&1; then
    if grep -qF '/etc/nginx/stream.d/' /etc/nginx/nginx.conf 2>/dev/null; then
      warn "nginx -t échoue — tentative repair stream (sudo ./install.sh repair-nginx-stream)"
      if [[ -x "${INFRA_ROOT}/scripts/repair-nginx-stream.sh" ]]; then
        bash "${INFRA_ROOT}/scripts/repair-nginx-stream.sh" || die "nginx invalide — lancer : sudo ./install.sh repair-nginx-stream"
      else
        die "nginx invalide — installer libnginx-mod-stream : sudo apt install -y libnginx-mod-stream"
      fi
    else
      die "nginx -t échoué"
    fi
  fi
  systemctl reload nginx
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

# Stunnel : accept = :::PORT (pas [::]:PORT — résolu comme hostname par stunnel4).
# Si net.ipv6.bindv6only=0, :::PORT accepte déjà v4+v6 → retirer les sections accept=PORT seules.
stunnel_ipv6_bindv6only() {
  sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 1
}

stunnel_strip_redundant_v4_listeners() {
  local conf tmp
  for conf in /etc/stunnel/conf.d/*.conf; do
    [[ -f "${conf}" ]] || continue
    tmp="$(mktemp)"
    awk '
      function flush() {
        if (block != "" && !drop_block) printf "%s", block
        block = ""
        drop_block = 0
      }
      /^\[/ {
        flush()
        block = $0 "\n"
        next
      }
      {
        block = block $0 "\n"
        if ($0 ~ /^accept = [0-9][0-9]*$/) drop_block = 1
        if ($0 ~ /^accept = :::[0-9]/) drop_block = 0
      }
      END { flush() }
    ' "${conf}" > "${tmp}"
    mv "${tmp}" "${conf}"
  done
}

stunnel_sync_conf_d() {
  for primary_conf in redis-cache.conf redis-bullmq.conf; do
    cp "${STUNNEL_CONF_SRC}/${primary_conf}" /etc/stunnel/conf.d/
  done
  if redis_cluster_b_enabled; then
    for replica_conf in \
      redis-cache-replica-1.conf \
      redis-cache-replica-2.conf \
      redis-bullmq-replica-1.conf \
      redis-bullmq-replica-2.conf; do
      cp "${STUNNEL_CONF_SRC}/${replica_conf}" /etc/stunnel/conf.d/
    done
  else
    rm -f /etc/stunnel/conf.d/redis-cache-replica-*.conf /etc/stunnel/conf.d/redis-bullmq-replica-*.conf
    log "Cluster-b désactivé — configs Stunnel réplicas retirées de conf.d"
  fi
  if [[ -f "${MEMCACHED_STUNNEL_CONF_SRC}/memcached-tls.conf" ]]; then
    cp "${MEMCACHED_STUNNEL_CONF_SRC}/memcached-tls.conf" /etc/stunnel/conf.d/
  fi
  if [[ -f "${INFRA_ROOT}/mongodb/stunnel/mongodb-tls.conf" ]] \
    && [[ -f "/etc/stunnel/mongodb/fullchain.pem" ]]; then
    cp "${INFRA_ROOT}/mongodb/stunnel/mongodb-tls.conf" /etc/stunnel/conf.d/
  else
    rm -f /etc/stunnel/conf.d/mongodb-tls.conf
  fi
  local bindv6only
  bindv6only="$(stunnel_ipv6_bindv6only)"
  log "net.ipv6.bindv6only=${bindv6only}"
  if [[ "${bindv6only}" == "0" ]]; then
    log "bindv6only=0 — listeners :::PORT couvrent v4+v6 ; retrait sections accept=PORT seules"
    stunnel_strip_redundant_v4_listeners
  fi
  chmod 644 /etc/stunnel/conf.d/*.conf 2>/dev/null || true
}

stunnel_restart_or_die() {
  ensure_stunnel_runtime
  if ! systemctl restart stunnel4; then
    warn "stunnel4 a échoué — journal (40 dernières lignes) :"
    journalctl -u stunnel4 -n 40 --no-pager 2>/dev/null || true
    stunnel_diagnose
    die "Corrigez /etc/stunnel/conf.d puis : sudo systemctl restart stunnel4"
  fi
  log "stunnel4 redémarré"
}

# Répertoire pid + foreground=no (obligatoire — sinon « inetd mode » / échec systemd).
# Réécrit stunnel.conf (canonical) : l’init Debian boucle sur FILES="/etc/stunnel/*.conf"
# et chaque fichier sans pid= global provoque l’erreur « inetd mode ».
ensure_stunnel_runtime() {
  mkdir -p /var/run/stunnel4 /var/log/stunnel4
  chown stunnel4:stunnel4 /var/run/stunnel4 /var/log/stunnel4
  chmod 755 /var/run/stunnel4 /var/log/stunnel4
  rm -f /var/run/stunnel4/stunnel.pid

  if [[ -f /etc/default/stunnel4 ]]; then
    if grep -q '^ENABLED=' /etc/default/stunnel4; then
      sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
    else
      echo 'ENABLED=1' >> /etc/default/stunnel4
    fi
    if grep -q '^FILES=' /etc/default/stunnel4; then
      sed -i 's|^FILES=.*|FILES="/etc/stunnel/stunnel.conf"|' /etc/default/stunnel4
    else
      echo 'FILES="/etc/stunnel/stunnel.conf"' >> /etc/default/stunnel4
    fi
  fi

  local main=/etc/stunnel/stunnel.conf
  mkdir -p /etc/stunnel/conf.d
  if [[ -f "${main}" ]] && ! grep -q 'Wise Eat — global stunnel' "${main}" 2>/dev/null; then
    cp -a "${main}" "${main}.bak.$(date +%s)"
    log "Sauvegarde ${main} → ${main}.bak.*"
  fi

  cat > "${main}" <<'EOF'
; Wise Eat — global stunnel (un seul daemon, services dans conf.d)
foreground = no
pid = /var/run/stunnel4/stunnel.pid
output = /var/log/stunnel4/stunnel.log
setuid = stunnel4
setgid = stunnel4
include = /etc/stunnel/conf.d
EOF

  local stray
  shopt -s nullglob
  for stray in /etc/stunnel/*.conf; do
    [[ "${stray}" == "${main}" ]] && continue
    warn "Fichier stunnel orphelin (init.d le lancerait sans pid=) : ${stray} — déplacé vers ${stray}.disabled"
    mv "${stray}" "${stray}.disabled"
  done
  shopt -u nullglob
}

stunnel_diagnose() {
  local main=/etc/stunnel/stunnel.conf
  log "=== Diagnostic stunnel ==="
  echo "--- /etc/default/stunnel4 ---"
  cat /etc/default/stunnel4 2>/dev/null || true
  echo "--- ${main} ---"
  cat "${main}" 2>/dev/null || true
  echo "--- /etc/stunnel/conf.d/ ---"
  ls -la /etc/stunnel/conf.d/ 2>/dev/null || true
  echo "--- test foreground (3s) ---"
  timeout 3 stunnel4 "${main}" -fd 2>&1 || true
}
