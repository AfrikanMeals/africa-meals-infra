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
MATOMO_DIR="${MATOMO_DIR:-${WISE_EAT_ROOT}/matomo}"
NEO4J_DIR="${NEO4J_DIR:-${WISE_EAT_ROOT}/neo4j}"
MON_DIR="${MON_DIR:-${WISE_EAT_ROOT}/monitoring}"
REDIS_ENV="${REDIS_ENV:-${REDIS_DIR}/.env.redis}"
MINIO_ENV="${MINIO_ENV:-${MINIO_DIR}/.env.minio}"
EMQX_ENV="${EMQX_ENV:-${EMQX_DIR}/.env.emqx}"
MONGODB_ENV="${MONGODB_ENV:-${MONGODB_DIR}/.env.mongodb}"
MATOMO_ENV="${MATOMO_ENV:-${MATOMO_DIR}/.env.matomo}"
NEO4J_ENV="${NEO4J_ENV:-${NEO4J_DIR}/.env.neo4j}"
NEO4J_DATA_DIR="${NEO4J_DATA_DIR:-/var/lib/wise-eat/neo4j}"
NEO4J_STORAGE_GB="${NEO4J_STORAGE_GB:-5}"
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
API_WISE_EAT_DOMAIN="${API_WISE_EAT_DOMAIN:-api.wise-eat.com}"
API_BACKEND_HOST="${API_BACKEND_HOST:-127.0.0.1}"
API_BACKEND_PORT="${API_BACKEND_PORT:-30900}"
WS_WISE_EAT_DOMAIN="${WS_WISE_EAT_DOMAIN:-ws.wise-eat.com}"
WS_BACKEND_HOST="${WS_BACKEND_HOST:-127.0.0.1}"
WS_BACKEND_PORT="${WS_BACKEND_PORT:-30800}"
REDIS_TLS_DOMAIN="${REDIS_TLS_DOMAIN:-cache.wise-eat.com}"
# Limite connexions TLS Stunnel 5.x (défaut ≈500 si ulimit=1024 — trop bas pour k8s + dev + réplicas).
# Stunnel calcule max_clients = max_fds×125/256 ; on règle RLIMITS=-n dans /etc/default/stunnel4.
STUNNEL_MAX_CLIENTS="${STUNNEL_MAX_CLIENTS:-5000}"
# Idle tunnel timeout (secondes) — 0 = garder ouvert (recommandé Mongo/Redis drivers).
# Injecté dans chaque service conf.d via stunnel_apply_service_defaults.
STUNNEL_TIMEOUT_IDLE="${STUNNEL_TIMEOUT_IDLE:-0}"
MEMCACHED_TLS_PORT="${MEMCACHED_TLS_PORT:-11212}"
GRAFANA_CONSOLE_DOMAIN="${GRAFANA_CONSOLE_DOMAIN:-console.wise-eat.com}"
GRAFANA_BACKEND_HOST="${GRAFANA_BACKEND_HOST:-127.0.0.1}"
GRAFANA_BACKEND_PORT="${GRAFANA_BACKEND_PORT:-3000}"
MATOMO_DOMAIN="${MATOMO_DOMAIN:-analytics.wise-eat.com}"
MATOMO_BACKEND_HOST="${MATOMO_BACKEND_HOST:-127.0.0.1}"
MATOMO_BACKEND_PORT="${MATOMO_BACKEND_PORT:-8089}"
MATOMO_DATA_DIR="${MATOMO_DATA_DIR:-/var/lib/wise-eat/matomo}"
MATOMO_STORAGE_GB="${MATOMO_STORAGE_GB:-5}"
K8S_DASHBOARD_DOMAIN="${K8S_DASHBOARD_DOMAIN:-k8s.wise-eat.com}"
K8S_DASHBOARD_BACKEND_HOST="${K8S_DASHBOARD_BACKEND_HOST:-127.0.0.1}"
K8S_DASHBOARD_BACKEND_PORT="${K8S_DASHBOARD_BACKEND_PORT:-30850}"
K8S_DASHBOARD_BASIC_AUTH_USER="${K8S_DASHBOARD_BASIC_AUTH_USER:-k8s-admin}"
K8S_DASHBOARD_HTASSWD_FILE="${K8S_DASHBOARD_HTASSWD_FILE:-/etc/nginx/htpasswd/k8s-dashboard}"
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
MINIO_STORAGE_GB="${MINIO_STORAGE_GB:-10}"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio}"
MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"
MONGO_ADMIN_DOMAIN="${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}"
MONGO_ADMIN_BACKEND_HOST="${MONGO_ADMIN_BACKEND_HOST:-127.0.0.1}"
MONGO_ADMIN_BACKEND_PORT="${MONGO_ADMIN_BACKEND_PORT:-8081}"
MONGO_ADMIN_BASIC_AUTH_USER="${MONGO_ADMIN_BASIC_AUTH_USER:-mongo-admin}"
MONGO_ADMIN_HTASSWD_FILE="${MONGO_ADMIN_HTASSWD_FILE:-/etc/nginx/htpasswd/mongo-admin}"
NEO4J_ADMIN_DOMAIN="${NEO4J_ADMIN_DOMAIN:-db-graph.wise-eat.com}"
NEO4J_ADMIN_BACKEND_HOST="${NEO4J_ADMIN_BACKEND_HOST:-127.0.0.1}"
NEO4J_ADMIN_BACKEND_PORT="${NEO4J_ADMIN_BACKEND_PORT:-7474}"
NEO4J_ADMIN_BASIC_AUTH_USER="${NEO4J_ADMIN_BASIC_AUTH_USER:-neo4j-admin}"
NEO4J_ADMIN_HTASSWD_FILE="${NEO4J_ADMIN_HTASSWD_FILE:-/etc/nginx/htpasswd/neo4j-admin}"
NEO4J_BOLT_TLS_PORT="${NEO4J_BOLT_TLS_PORT:-7688}"
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

# Basic auth nginx pour Headlamp public (k8s.wise-eat.com).
ensure_k8s_dashboard_basic_auth_file() {
  local user="${K8S_DASHBOARD_BASIC_AUTH_USER:-k8s-admin}"
  local pass="${K8S_DASHBOARD_BASIC_AUTH_PASSWORD:-}"
  local file="${K8S_DASHBOARD_HTASSWD_FILE}"

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "K8S_DASHBOARD_BASIC_AUTH_PASSWORD requis (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth Headlamp : ${user} → ${file}"
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

# Basic auth nginx pour Neo4j Admin public (db-graph.wise-eat.com).
ensure_neo4j_admin_basic_auth_file() {
  local user="${NEO4J_ADMIN_BASIC_AUTH_USER:-neo4j-admin}"
  local pass="${NEO4J_ADMIN_BASIC_AUTH_PASSWORD:-}"
  local file="${NEO4J_ADMIN_HTASSWD_FILE}"

  if [[ -z "${pass}" ]] && [[ -f "${NEO4J_ENV}" ]]; then
    pass="$(read_env_var_from_file "${NEO4J_ENV}" NEO4J_ADMIN_BASIC_AUTH_PASSWORD || true)"
  fi

  if [[ -z "${pass}" ]] && [[ ! -f "${file}" ]]; then
    die "NEO4J_ADMIN_BASIC_AUTH_PASSWORD requis dans ${NEO4J_ENV} (ou fichier ${file} déjà présent)"
  fi

  mkdir -p "$(dirname "${file}")"
  apt install -y apache2-utils 2>/dev/null || true
  command -v htpasswd >/dev/null 2>&1 || die "apache2-utils requis (htpasswd)"

  if [[ -n "${pass}" ]]; then
    htpasswd -bc "${file}" "${user}" "${pass}"
    chmod 640 "${file}"
    chown root:www-data "${file}" 2>/dev/null || true
    log "Basic auth Neo4j Admin : ${user} → ${file}"
  elif [[ -f "${file}" ]]; then
    log "Basic auth Neo4j Admin : ${file} (inchangé)"
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
      --exclude '.env.mongodb' --exclude '.env.matomo' --exclude '.env.ollama' \
      --exclude '.env.neo4j' \
      --exclude 'data-cache/' --exclude 'data-bullmq/' \
      --exclude 'data-cache-replica/' --exclude 'data-bullmq-replica/' \
      --exclude 'data-cache-replica-1/' --exclude 'data-cache-replica-2/' \
      --exclude 'data-bullmq-replica-1/' --exclude 'data-bullmq-replica-2/' \
      --exclude 'data-emqx-1/' --exclude 'data-emqx-2/' --exclude 'data-emqx-3/' \
      --exclude 'data-mongo-1/' --exclude 'data-mongo-2/' --exclude 'data-mongo-3/' \
      --exclude 'data-dbgate/' \
      --exclude 'data/' \
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
  # shellcheck source=lib/vps-swap.sh
  source "$(dirname "${BASH_SOURCE[0]}")/vps-swap.sh"
  ensure_vps_memory_tuning
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

cadvisor_has_container_metrics() {
  local metrics
  metrics="$(curl -sf --max-time 5 http://127.0.0.1:8088/metrics 2>/dev/null || true)"
  [[ -n "${metrics}" ]] || return 1
  echo "${metrics}" | grep '^container_cpu_usage_seconds_total' | grep -v 'id="/"' | grep -q .
}

cadvisor_scrape_up() {
  curl -sfG --max-time 5 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=up{job="cadvisor",instance="wise-eat:8080"}' 2>/dev/null \
    | grep -q '"value":\[".*","1"\]'
}

diagnose_cadvisor_port() {
  echo "Diagnostic cAdvisor :8088 :" >&2
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep ':8088' || echo "  rien n'écoute sur :8088" >&2
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-cadvisor'; then
    docker inspect wise-eat-cadvisor \
      --format '  status={{.State.Status}} restarts={{.RestartCount}} net={{.HostConfig.NetworkMode}}' \
      2>/dev/null >&2 || true
    docker logs wise-eat-cadvisor --tail 20 2>&1 | sed 's/^/  log /' >&2 || true
  else
    echo "  conteneur wise-eat-cadvisor absent" >&2
  fi
}

ensure_cadvisor() {
  ensure_docker
  ensure_wise_eat_infra_network
  cd "${MON_DIR}"
  monitoring_compose_args

  if cadvisor_has_container_metrics && cadvisor_scrape_up; then
    log "OK cAdvisor :8088 + scrape Prometheus"
    return 0
  fi

  if cadvisor_has_container_metrics; then
    log "OK cAdvisor :8088 — reload Prometheus scrape"
    curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 \
      || docker restart wise-eat-prometheus >/dev/null 2>&1 || true
    sleep 5
    cadvisor_scrape_up && return 0
  fi

  warn "cAdvisor :8088 injoignable — recréation conteneur..."
  diagnose_cadvisor_port

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-cadvisor'; then
    docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --force-recreate --no-deps cadvisor
  else
    docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --no-deps cadvisor
  fi

  if wait_for_cadvisor_container_metrics 60; then
    curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 \
      || docker restart wise-eat-prometheus >/dev/null 2>&1 || true
    sleep 5
    if cadvisor_scrape_up; then
      log "OK cAdvisor scrape up{job=cadvisor,instance=wise-eat:8080}=1"
      return 0
    fi
    warn "cAdvisor :8088 OK mais scrape Prometheus DOWN — sudo scripts/repair-prometheus-host-targets.sh"
    return 0
  fi

  diagnose_cadvisor_port
  local storage_driver
  storage_driver="$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')"
  if [[ "${storage_driver}" == "overlayfs" ]]; then
    warn "Docker 29 overlayfs — essayer : sudo ./install.sh repair-docker-daemon-cadvisor"
  fi
  return 1
}

wait_for_cadvisor_container_metrics() {
  local max="${1:-60}"
  local i
  for i in $(seq 1 "$max"); do
    if cadvisor_has_container_metrics; then
      log "cAdvisor remonte des métriques conteneur (tentative ${i}/${max})"
      return 0
    fi
    sleep 2
  done
  return 1
}

monitoring_compose_args() {
  MONITORING_COMPOSE_ARGS=(--env-file .env.monitoring)
  if [[ -n "$(wise_eat_compose_profiles || true)" ]]; then
    MONITORING_COMPOSE_ARGS+=(--profile cluster-b)
  fi
}

node_exporter_metrics_ok() {
  curl -sf --max-time 5 http://127.0.0.1:9100/metrics 2>/dev/null \
    | grep -q '^node_cpu_seconds_total'
}

diagnose_node_exporter_port() {
  echo "Diagnostic node_exporter :9100 :" >&2
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep ':9100' || echo "  rien n'écoute sur :9100" >&2
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-node-exporter'; then
    docker inspect wise-eat-node-exporter \
      --format '  status={{.State.Status}} restarts={{.RestartCount}} net={{.HostConfig.NetworkMode}}' \
      2>/dev/null >&2 || true
    docker port wise-eat-node-exporter 2>&1 | sed 's/^/  port /' >&2 || true
    docker logs wise-eat-node-exporter --tail 20 2>&1 | sed 's/^/  log /' >&2 || true
  else
    echo "  conteneur wise-eat-node-exporter absent" >&2
  fi
}

ensure_node_exporter() {
  ensure_docker
  ensure_wise_eat_infra_network
  cd "${MON_DIR}"
  monitoring_compose_args

  if node_exporter_metrics_ok; then
    return 0
  fi

  warn "node_exporter :9100 injoignable — recréation conteneur..."
  diagnose_node_exporter_port

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-node-exporter'; then
    docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --force-recreate --no-deps node-exporter
  else
    docker compose "${MONITORING_COMPOSE_ARGS[@]}" up -d --no-deps node-exporter
  fi

  local i
  for i in $(seq 1 15); do
    sleep 2
    if node_exporter_metrics_ok; then
      log "OK node_exporter :9100 (tentative ${i}/15)"
      return 0
    fi
  done

  diagnose_node_exporter_port
  return 1
}

ensure_prometheus_ready() {
  local k8s_scripts="${INFRA_ROOT}/k8s/scripts"
  if ! curl -sf --max-time 5 http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
    warn "Prometheus :9090 injoignable"
    if [[ -x "${k8s_scripts}/recreate-prometheus-host.sh" ]]; then
      "${k8s_scripts}/recreate-prometheus-host.sh" || return 1
    else
      return 1
    fi
  fi

  local prom_mode
  prom_mode="$(docker inspect wise-eat-prometheus -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${prom_mode}" != "host" ]]; then
    warn "Prometheus pas en network_mode=host — migration..."
    [[ -x "${k8s_scripts}/recreate-prometheus-host.sh" ]] \
      && "${k8s_scripts}/recreate-prometheus-host.sh" \
      || return 1
  fi

  if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
    log "Prometheus rechargé (/-/reload)"
  else
    docker restart wise-eat-prometheus >/dev/null 2>&1 || return 1
    sleep 3
  fi
  return 0
}

ensure_grafana_prometheus_link() {
  local k8s_scripts="${INFRA_ROOT}/k8s/scripts"

  ensure_prometheus_ready || {
    warn "Prometheus indisponible — Grafana affichera N/A partout"
    return 1
  }

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-grafana'; then
    warn "Grafana absent — recréation (host network + datasource 127.0.0.1:9090)"
    [[ -x "${k8s_scripts}/recreate-grafana-host.sh" ]] \
      && "${k8s_scripts}/recreate-grafana-host.sh" \
      || return 1
    return 0
  fi

  local grafana_net
  grafana_net="$(docker inspect wise-eat-grafana -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${grafana_net}" != "host" ]]; then
    warn "Grafana en réseau « ${grafana_net} » — 127.0.0.1:9090 injoignable → dashboards N/A"
    [[ -x "${k8s_scripts}/recreate-grafana-host.sh" ]] \
      && "${k8s_scripts}/recreate-grafana-host.sh" \
      || return 1
    sleep 3
  fi

  if docker exec wise-eat-grafana wget -qO- --timeout=5 http://127.0.0.1:9090/-/ready 2>/dev/null \
    | grep -qi prometheus; then
    log "OK Grafana → Prometheus (127.0.0.1:9090)"
    return 0
  fi

  warn "Grafana ne joint pas Prometheus — recréation conteneur + reprovision datasource"
  [[ -x "${k8s_scripts}/recreate-grafana-host.sh" ]] \
    && "${k8s_scripts}/recreate-grafana-host.sh" \
    || return 1
  sleep 3
  docker exec wise-eat-grafana wget -qO- --timeout=5 http://127.0.0.1:9090/-/ready 2>/dev/null \
    | grep -qi prometheus
}

prometheus_has_series() {
  curl -sfG --max-time 10 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=count(up==1)' 2>/dev/null \
    | grep -q '"value":\[".*","[1-9]'
}

verify_ollama_exporter_metrics() {
  local max="${1:-30}"
  local i
  for i in $(seq 1 "$max"); do
    if curl -sf http://127.0.0.1:9400/metrics 2>/dev/null | grep -q '^ollama_up 1'; then
      log "ollama-exporter remonte ollama_up=1 (tentative ${i}/${max})"
      return 0
    fi
    sleep 2
  done
  warn "ollama-exporter ne remonte pas ollama_up=1 — sudo ./install.sh monitoring"
  return 1
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
  local line val
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 1
  val="${line#*=}"
  if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
    val="${BASH_REMATCH[1]}"
  elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${val}"
}

# Charge un fichier .env sans casser sur les valeurs non quotées avec espaces
# (ex. GRAFANA_SMTP_FROM_NAME=Wise Eat Alerts → « Eat: command not found »).
source_dotenv() {
  local file="$1"
  local line key val
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    printf -v "${key}" '%s' "${val}"
    export "${key}"
  done < "${file}"
}

# Conteneurs créés hors Compose (recreate-*-host.sh) bloquent le même container_name.
reconcile_monitoring_compose_named_containers() {
  local name project
  for name in wise-eat-prometheus wise-eat-grafana; do
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
      continue
    fi
    project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${name}" 2>/dev/null || true)"
    if [[ -z "${project}" ]]; then
      warn "Conteneur ${name} hors Compose — suppression pour recréation compose"
      docker rm -f "${name}" >/dev/null 2>&1 || true
    fi
  done
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

# Corrige les lignes .env.monitoring connues pour casser un `source` bash.
sanitize_monitoring_env_file() {
  local file="${1:-${MON_DIR}/.env.monitoring}"
  [[ -f "${file}" ]] || return 0
  # GRAFANA_SMTP_FROM_NAME=Wise Eat Alerts → quotes
  if grep -qE '^GRAFANA_SMTP_FROM_NAME=Wise Eat' "${file}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    sed 's/^GRAFANA_SMTP_FROM_NAME=Wise Eat Alerts$/GRAFANA_SMTP_FROM_NAME="Wise Eat Alerts"/' "${file}" \
      | sed 's/^GRAFANA_SMTP_FROM_NAME=Wise Eat.*/GRAFANA_SMTP_FROM_NAME="Wise Eat Alerts"/' \
      > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
    log "Corrigé GRAFANA_SMTP_FROM_NAME quoté dans ${file}"
  fi
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

# Stunnel 5.x : max_clients = max_fds×125/256 (voir src/fd.c) — pas d’option maxClients en conf.
stunnel_nofile_for_clients() {
  local clients="${1:-${STUNNEL_MAX_CLIENTS}}"
  echo $(( (clients * 256 + 124) / 125 ))
}

stunnel_apply_service_defaults() {
  local conf idle="${STUNNEL_TIMEOUT_IDLE}"
  for conf in /etc/stunnel/conf.d/*.conf; do
    [[ -f "${conf}" ]] || continue
    if grep -q '^TIMEOUTidle' "${conf}"; then
      sed -i "s/^TIMEOUTidle = .*/TIMEOUTidle = ${idle}/" "${conf}"
    else
      sed -i "/^connect = /a TIMEOUTidle = ${idle}" "${conf}"
    fi
  done
}

stunnel_configure_rlimits() {
  local nofile
  nofile="$(stunnel_nofile_for_clients)"
  [[ -f /etc/default/stunnel4 ]] || return 0
  if grep -q '^RLIMITS=' /etc/default/stunnel4; then
    sed -i "s|^RLIMITS=.*|RLIMITS=\"-n ${nofile}\"|" /etc/default/stunnel4
  else
    echo "RLIMITS=\"-n ${nofile}\"" >> /etc/default/stunnel4
  fi
  log "stunnel4 RLIMITS=-n ${nofile} (≈${STUNNEL_MAX_CLIENTS} clients TLS max)"
}

# Stunnel dual-stack :
#   accept = 0.0.0.0:PORT  → IPv4 only (pods k3s / cni0 — évite ::ffff: + ECONNRESET)
#   accept = :::PORT       → IPv6 only (pas [::]:PORT — résolu comme hostname par stunnel4)
# Exige net.ipv6.bindv6only=1. Si =0, :::PORT accepte aussi le v4 → conflit / path ::ffff cassé.
stunnel_ipv6_bindv6only() {
  sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 1
}

# Force bindv6only=1 pour cohabiter 0.0.0.0:PORT + :::PORT sans Address already in use.
stunnel_ensure_bindv6only() {
  local cur
  cur="$(stunnel_ipv6_bindv6only)"
  if [[ "${cur}" == "1" ]]; then
    log "net.ipv6.bindv6only=1 (OK — listeners IPv4/IPv6 séparés)"
    return 0
  fi
  log "net.ipv6.bindv6only=${cur} → forcer 1 (requis pour accept=0.0.0.0:PORT + :::PORT)"
  sysctl -w net.ipv6.bindv6only=1 >/dev/null
  mkdir -p /etc/sysctl.d
  echo 'net.ipv6.bindv6only=1' > /etc/sysctl.d/99-wise-eat-bindv6only.conf
}

# Si une conf legacy a encore « accept = PORT » (sans 0.0.0.0), le réécrire en IPv4 explicite.
stunnel_normalize_v4_accept_listeners() {
  local conf
  for conf in /etc/stunnel/conf.d/*.conf; do
    [[ -f "${conf}" ]] || continue
    # accept = 6381  →  accept = 0.0.0.0:6381  (ne touche pas ::: ni 0.0.0.0 déjà présents)
    sed -i -E 's/^accept = ([0-9]+)$/accept = 0.0.0.0:\1/' "${conf}"
  done
}

stunnel_sync_conf_d() {
  stunnel_ensure_bindv6only
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
  stunnel_normalize_v4_accept_listeners
  log "net.ipv6.bindv6only=$(stunnel_ipv6_bindv6only) — listeners 0.0.0.0:PORT + :::PORT"
  stunnel_apply_service_defaults
  chmod 644 /etc/stunnel/conf.d/*.conf 2>/dev/null || true
}

stunnel_stop_all() {
  systemctl stop stunnel4 2>/dev/null || true
  if pgrep -x stunnel4 >/dev/null 2>&1; then
    log "Arrêt processus stunnel4 orphelins…"
    pkill -TERM stunnel4 2>/dev/null || true
    sleep 2
    pkill -KILL stunnel4 2>/dev/null || true
    sleep 1
  fi
  rm -f /var/run/stunnel4/stunnel.pid
}

stunnel_restart_or_die() {
  ensure_stunnel_runtime
  stunnel_stop_all
  if ! systemctl start stunnel4; then
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

  cat > "${main}" <<EOF
; Wise Eat — global stunnel (un seul daemon, services dans conf.d)
foreground = no
pid = /var/run/stunnel4/stunnel.pid
output = /var/log/stunnel4/stunnel.log
setuid = stunnel4
setgid = stunnel4
include = /etc/stunnel/conf.d
EOF
  stunnel_configure_rlimits
  if [[ "${STUNNEL_TIMEOUT_IDLE}" == "0" ]]; then
    log "stunnel.conf — TIMEOUTidle=0 (idle timeout désactivé) par service (conf.d)"
  else
    log "stunnel.conf — TIMEOUTidle=${STUNNEL_TIMEOUT_IDLE}s par service (conf.d)"
  fi

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
