#!/usr/bin/env bash
# Wise Eat — installation infra VPS par composant.
#
# Usage:
#   sudo ./install.sh redis
#   sudo ./install.sh memcached
#   sudo ./install.sh minio
#   sudo STUNNEL_TLS_EMAIL=you@wise-eat.com ./install.sh certbot
#   sudo ./install.sh stunnel
#   sudo ./install.sh monitoring
#   sudo ./install.sh permissions
#   sudo ./install.sh all
#   ./install.sh --help
#
# Variables:
#   WISE_EAT_ROOT   Racine déploiement (défaut : répertoire de ce dépôt)
#   STUNNEL_TLS_EMAIL   Let's Encrypt (certbot)
#   REDIS_TLS_DOMAIN    Hostname Redis TLS (défaut cache.wise-eat.com)
#   STUNNEL_TLS_DOMAIN  Alias (défaut = REDIS_TLS_DOMAIN)
#   GCP_EGRESS_IP       A-strict optionnel (Cloud NAT)
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${INFRA_ROOT}/scripts"

usage() {
  cat <<EOF
Wise Eat — installateur infra VPS

Usage:
  sudo $0 <composant> [composant...]
  sudo $0 all

Composants:
  redis         Redis 1 primary (:6379/:6380) + 2 réplicas chacun
  memcached     Memcached 1 primary (:11211) + 2 réplicas
  minio         MinIO Docker (S3 :9000, console :9001, volume 25G)
  minio-storage nginx reverse-proxy → MinIO S3 (storage.wise-eat.com)
  minio-console  nginx reverse-proxy → MinIO Console (cdn.wise-eat.com, basic auth)
  repair-minio-prometheus  Répare scrape Prometheus → MinIO (Grafana vide)
  minio-backup  Cron sauvegarde incrémentale MinIO (mc mirror)
  minio-replication  MinIO + 2 réplicas site replication (:9002, :9004)
  minio-replica-storage  nginx + TLS LE pour dr1/dr2-storage.wise-eat.com
  repair-minio-replication  Répare site replication (buckets réplicas + mc)
  nginx         nginx + reverse-proxy WS + webroot Certbot
  apache        apache2 + reverse-proxy WS + webroot Certbot
  web           nginx ou apache (WEB_SERVER=nginx|apache, défaut nginx)
  certbot       Let's Encrypt (WS + Redis Stunnel + Grafana + Prometheus + MinIO)
  stunnel       Stunnel TLS A-lite (:6381 / :6382 / :11212 Memcached)
  tls           certbot + stunnel (nginx requis pour webroot)
  verify-tls    Vérifie certs LE + Stunnel
  monitoring    Prometheus + Grafana + node/redis/memcached exporters
  repair-monitoring  Répare exporters + sync mots de passe Redis (Grafana vide)
  grafana-console nginx reverse-proxy → Grafana (console.wise-eat.com)
  redis-stunnel-cert  Certbot cache.wise-eat.com + sync Stunnel (TLS Redis)
  prometheus-logs nginx reverse-proxy → Prometheus (logs.wise-eat.com, basic auth)
  permissions   Corrige ACL/data (UID 999)
  all           redis + permissions + monitoring + memcached + minio

Stack TLS prod (nginx recommandé) :
  sudo $0 nginx
  sudo STUNNEL_TLS_EMAIL=help@wise-eat.com $0 tls
  # tls = certbot + stunnel (nginx doit être actif pour webroot)

Apache à la place de nginx :
  sudo WEB_SERVER=apache $0 web
  sudo STUNNEL_TLS_EMAIL=help@wise-eat.com $0 certbot
  sudo $0 stunnel

Exemples:
  sudo $0 redis
  sudo $0 memcached
  sudo $0 minio
  sudo $0 stunnel
  sudo GCP_EGRESS_IP=203.0.113.50 $0 stunnel
  sudo $0 redis monitoring
  sudo $0 all

Env:
  WISE_EAT_ROOT=${WISE_EAT_ROOT:-$INFRA_ROOT}
  WS_BACKEND_PORT=8000
  WEB_SERVER=nginx|apache
  GCP_EGRESS_IP=<ip>   A-strict optionnel

Docs: README.md · docs/REDIS_VPS_PRODUCTION.md (monorepo AfrikaMeals)
EOF
}

run_component() {
  local name="$1"
  case "${name}" in
    redis)
      bash "${SCRIPTS}/install-redis.sh"
      ;;
    memcached)
      bash "${SCRIPTS}/install-memcached.sh"
      ;;
    minio)
      bash "${SCRIPTS}/install-minio.sh"
      ;;
    minio-storage)
      bash "${SCRIPTS}/install-minio-storage.sh"
      ;;
    minio-console)
      bash "${SCRIPTS}/install-minio-console.sh"
      ;;
    repair-minio-prometheus)
      bash "${SCRIPTS}/repair-minio-prometheus.sh"
      ;;
    minio-backup)
      bash "${SCRIPTS}/install-minio-backup.sh"
      ;;
    minio-replication)
      bash "${SCRIPTS}/install-minio-replication.sh"
      ;;
    minio-replica-storage)
      bash "${SCRIPTS}/install-minio-replica-storage.sh"
      ;;
    repair-minio-replication)
      bash "${SCRIPTS}/repair-minio-replication.sh"
      ;;
    nginx)
      bash "${SCRIPTS}/install-nginx.sh"
      ;;
    apache)
      bash "${SCRIPTS}/install-apache.sh"
      ;;
    web)
      bash "${SCRIPTS}/install-web.sh"
      ;;
    certbot)
      bash "${SCRIPTS}/install-certbot.sh"
      ;;
    stunnel)
      bash "${SCRIPTS}/install-stunnel.sh"
      ;;
    tls)
      bash "${SCRIPTS}/install-certbot.sh"
      bash "${SCRIPTS}/install-stunnel.sh"
      ;;
    verify-tls)
      bash "${SCRIPTS}/verify-tls.sh"
      ;;
    monitoring)
      bash "${SCRIPTS}/install-monitoring.sh"
      ;;
    repair-monitoring)
      bash "${SCRIPTS}/repair-monitoring.sh"
      ;;
    grafana-console)
      bash "${SCRIPTS}/install-grafana-console.sh"
      ;;
    redis-stunnel-cert)
      bash "${SCRIPTS}/issue-redis-stunnel-cert.sh"
      ;;
    prometheus-logs)
      bash "${SCRIPTS}/install-prometheus-logs.sh"
      ;;
    permissions)
      bash "${SCRIPTS}/fix-redis-permissions.sh"
      ;;
    all)
      bash "${SCRIPTS}/install-redis.sh"
      bash "${SCRIPTS}/fix-redis-permissions.sh"
      bash "${SCRIPTS}/install-memcached.sh"
      bash "${SCRIPTS}/install-minio.sh"
      bash "${SCRIPTS}/install-monitoring.sh"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "Composant inconnu : ${name}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

for arg in "$@"; do
  run_component "${arg}"
done
