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
  redis         Redis Docker cache+bull (:6379/:6380) + réplicas — legacy
  redis-k8s     Applique pods Redis k8s (hostPath AOF + hostPort)
  migrate-redis-k8s  Cutover Redis Docker → K8s (zéro perte AOF)
  repair-redis-exporters  Exporters Grafana Redis → 127.0.0.1 (post-cutover)
  memcached     Memcached Docker 1 primary (:11211) + 2 réplicas — legacy
  memcached-k8s Applique pods Memcached k8s (hostPort 11211/11213/11214)
  migrate-memcached-k8s  Cutover Memcached Docker → K8s (cache froid attendu)
  repair-memcached-exporters  Exporters Grafana → 127.0.0.1 (post-cutover k8s)
  minio         MinIO Docker (S3 :9000, console :9001, volume 10G) — legacy
  minio-k8s     Applique pods MinIO k8s (secret + kustomize, hostPath existant)
  migrate-minio-k8s  Cutover prod Docker → K8s (backup + stop + apply, zéro perte)
  repair-minio-site-replication-k8s  Reconfigure SR MinIO (Services k8s, plus DNS Docker)
  emqx          EMQX MQTT Docker 1 primary (:1883) + 2 réplicas — legacy
  emqx-k8s      Applique pods EMQX k8s (hostPath Mnesia + hostPort primary)
  migrate-emqx-k8s  Cutover EMQX Docker → K8s (zéro perte data-emqx-*)

  mongodb       MongoDB 8 Docker rs0 (1 primary + 2 réplicas) — legacy
  mongodb-k8s   Applique pods Mongo k8s (hostPath + hostPort 27017/27027/27028)
  migrate-mongodb-k8s  Cutover Mongo Docker → K8s (dump + zéro perte)
  repair-mongodb-exporters  Exporter Grafana → host.docker.internal:27017
  ollama        Ollama Docker (nomic-embed-text + llama3.2:3b, :11434 local)
  ollama-gateway nginx reverse-proxy → Ollama (ai.wise-eat.com, basic auth, IPv4/IPv6)
  repair-ollama-monitoring Recréer Ollama + ollama-exporter (Grafana #25086)
  ollama-warmup-metrics  Charge un modèle + requête proxy (remplir dashboard Ollama)
  mongodb-tls   HAProxy/Stunnel TLS MongoDB (db.wise-eat.com :27018) — préférer haproxy
  haproxy       HAProxy TLS TCP (Mongo/Redis/Memcached) + UI https://proxy.wise-eat.com/stats
  haproxy-proxy nginx → HAProxy stats (proxy.wise-eat.com, basic auth)
  repair-haproxy  Répare HAProxy TLS + UI proxy.wise-eat.com
  mongodb-admin nginx reverse-proxy → DbGate (data.wise-eat.com, basic auth)
  neo4j-admin   nginx → Neo4j Browser (db-graph.wise-eat.com) + Bolt TLS :7688
  repair-neo4j-admin  Répare Neo4j Browser + nginx (db-graph.wise-eat.com 502)
  mongodb-backup Cron sauvegarde MongoDB (dump quotidien + snapshot hebdo)
  mongodb-cloud-backup Cron upload hebdo MongoDB → GCS / Firebase / AWS (Backup_DB_1…4)
  mongodb-cloud-tools  Installe gcloud + aws CLI (upload cloud MongoDB)
  repair-mongodb-prometheus  Répare scrape Prometheus → MongoDB (Grafana No data)
  repair-neo4j-prometheus  Répare scrape Prometheus → Neo4j (Grafana Neo4j No data)
  repair-mongodb-replicaset  Termine rs.initiate() si install bloqué
  repair-mongodb-admin     Répare DbGate + nginx (data.wise-eat.com 502)
  repair-mongodb-tls       Legacy Stunnel Mongo — préférer repair-haproxy
  rename-mongodb-database  Renomme la base app (african_meals_db → wise_eat_db) + droits + copie
  emqx-broker   nginx MQTTS/WSS (broker.wise-eat.com :8883/:8884)
  emqx-worker   nginx reverse-proxy → EMQX Dashboard (worker.wise-eat.com, basic auth)
  minio-storage nginx reverse-proxy → MinIO S3 (storage.wise-eat.com)
  minio-console  nginx reverse-proxy → MinIO Console (cdn.wise-eat.com, basic auth)
  repair-minio-prometheus  Répare scrape Prometheus → MinIO (Grafana vide)
  verify-minio-ops  Health API + console Admin (cdn) + scrape Grafana/Prometheus
  repair-emqx-prometheus   Répare scrape Prometheus → EMQX (Grafana No data)
  repair-emqx-boot         Recovery EMQX crash-loop (502 worker / schema prometheus)
  repair-emqx-cluster      Force 3 nœuds EMQX (primary + 2 réplicas)
  repair-emqx-auth       Répare users MQTT + ACL EMQX (not authorised)
  repair-nginx-stream      Module nginx stream (fix « unknown directive stream »)
  minio-backup  Cron sauvegarde incrémentale MinIO (mc mirror)
  minio-replication  MinIO + 2 réplicas site replication (:9002, :9004)
  minio-replica-storage  nginx + TLS LE pour dr1/dr2-storage.wise-eat.com
  repair-minio-replication  Répare site replication (buckets réplicas + mc)
  nginx         nginx + reverse-proxy WS + Certbot webroot
  apache        apache2 + reverse-proxy WS + webroot Certbot
  web           nginx ou apache (WEB_SERVER=nginx|apache, défaut nginx)
  certbot       Let's Encrypt (WS + API + Redis TLS + Grafana + proxy + …)
  api-tls       HTTPS api.wise-eat.com → k3s :30900 (Let's Encrypt nginx)
  ws-tls        HTTPS ws.wise-eat.com → k3s :30800 (Let's Encrypt nginx)
  stunnel       Stunnel TLS (legacy) — préférer ./install.sh haproxy
  tls           certbot + haproxy (TLS TCP Redis/Mongo/Memcached + UI proxy)
  verify-tls    Vérifie certs LE + HAProxy/Stunnel
  verify-ipv6-endpoints  Test AAAA + TCP/TLS depuis Mac ou VPS (./scripts/… sans sudo)
  repair-ipv6-ufw  UFW IPv6 + ports TLS/MQTT + hairpin broker (sur VPS)
  monitoring    Prometheus + Grafana + exporters + Loki/Promtail
  loki          Loki + Promtail (logs → Grafana dossier Logs)
  repair-monitoring  Répare exporters + sync mots de passe Redis (Grafana vide)
  repair-prometheus-host-targets  Corrige node_exporter DOWN (prometheus.yml → 127.0.0.1:9100)
  repair-grafana-stack  Grafana N/A partout : exporters + Prometheus + datasource
  repair-cadvisor    Recréer cAdvisor (métriques conteneurs Docker / Grafana #4271)
  repair-docker-daemon-cadvisor  Docker 29 overlayfs → désactive containerd-snapshotter
  reset-grafana-dashboards-git  Réinitialise dashboards Grafana avant git pull (VPS)
  grafana-console nginx reverse-proxy → Grafana (console.wise-eat.com)
  matomo        Matomo Analytics Docker (MariaDB + Apache, :8089 local)
  neo4j         Neo4j Community Docker (Bolt :7687, 1 Go RAM, volume 5 Go) — legacy
  neo4j-k8s     Applique pod Neo4j k8s (hostPath + hostPort 7474/7687)
  migrate-neo4j-k8s  Cutover Neo4j Docker → K8s (zéro perte volume)
  repair-neo4j-exporters  Exporter Grafana → host.docker.internal:7687 (post-cutover)
  matomo-gateway nginx reverse-proxy → Matomo (analytics.wise-eat.com)
  update-matomo   Mise à jour Matomo via CLI (image Docker + core:update)
  repair-matomo   Recovery crash / 502 / update interrompue
  redis-stunnel-cert  Certbot cache.wise-eat.com + sync certs TLS Redis
  prometheus-logs nginx reverse-proxy → Prometheus (logs.wise-eat.com, basic auth)
  permissions   Corrige ACL/data (UID 999)
  all           redis + permissions + monitoring + memcached + minio + emqx + mongodb

Stack TLS prod (nginx recommandé) :
  sudo $0 nginx
  sudo STUNNEL_TLS_EMAIL=help@wise-eat.com $0 tls
  # tls = certbot + haproxy (nginx doit être actif pour webroot)

Apache à la place de nginx :
  sudo WEB_SERVER=apache $0 web
  sudo STUNNEL_TLS_EMAIL=help@wise-eat.com $0 certbot
  sudo $0 haproxy

Exemples:
  sudo $0 redis
  sudo $0 memcached
  sudo $0 minio
  sudo $0 haproxy
  sudo GCP_EGRESS_IP=203.0.113.50 $0 haproxy
  sudo $0 redis monitoring
  sudo $0 all

Env:
  WISE_EAT_ROOT=${WISE_EAT_ROOT:-$INFRA_ROOT}
  WS_BACKEND_PORT=8000
  WEB_SERVER=nginx|apache
  GCP_EGRESS_IP=<ip>   A-strict optionnel
  HAPROXY_PROXY_BASIC_AUTH_PASSWORD=<pass>  UI proxy.wise-eat.com

Docs: README.md · docs/REDIS_VPS_PRODUCTION.md (monorepo AfrikaMeals)
EOF
}

run_component() {
  local name="$1"
  case "${name}" in
    redis)
      bash "${SCRIPTS}/install-redis.sh"
      ;;
    redis-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/create-redis-secret.sh"
      # Les 2 LimitRange du ns wise-eat : le max le plus bas s’applique.
      if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        sudo k3s kubectl apply -f "${INFRA_ROOT}/k8s/africa-meals-api/limitrange.yaml" || true
        sudo k3s kubectl apply -f "${INFRA_ROOT}/k8s/africa-meals-ws/limitrange.yaml" || true
        sudo k3s kubectl apply -k "${INFRA_ROOT}/k8s/redis"
      else
        kubectl apply -f "${INFRA_ROOT}/k8s/africa-meals-api/limitrange.yaml" || true
        kubectl apply -f "${INFRA_ROOT}/k8s/africa-meals-ws/limitrange.yaml" || true
        kubectl apply -k "${INFRA_ROOT}/k8s/redis"
      fi
      bash "${SCRIPTS}/ufw-allow-k3s-pods.sh" 2>/dev/null || true
      ;;
    migrate-redis-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/migrate-redis-docker-to-k8s.sh"
      ;;
    repair-redis-exporters)
      bash "${INFRA_ROOT}/k8s/scripts/repair-redis-exporters-host.sh"
      ;;
    memcached)
      bash "${SCRIPTS}/install-memcached.sh"
      ;;
    memcached-k8s)
      if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        sudo k3s kubectl apply -k "${INFRA_ROOT}/k8s/memcached"
      else
        kubectl apply -k "${INFRA_ROOT}/k8s/memcached"
      fi
      bash "${SCRIPTS}/ufw-allow-k3s-pods.sh" 2>/dev/null || true
      ;;
    migrate-memcached-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/migrate-memcached-docker-to-k8s.sh"
      ;;
    repair-memcached-exporters)
      bash "${INFRA_ROOT}/k8s/scripts/repair-memcached-exporters-host.sh"
      ;;
    minio)
      bash "${SCRIPTS}/install-minio.sh"
      ;;
    minio-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/create-minio-secret.sh"
      if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        sudo k3s kubectl apply -k "${INFRA_ROOT}/k8s/minio"
      else
        kubectl apply -k "${INFRA_ROOT}/k8s/minio"
      fi
      bash "${SCRIPTS}/ufw-allow-k3s-pods.sh" 2>/dev/null || true
      ;;
    migrate-minio-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/migrate-minio-docker-to-k8s.sh"
      ;;
    repair-minio-site-replication-k8s)
      # Post-cutover : endpoints SR Docker morts → Services *.svc.cluster.local
      bash "${INFRA_ROOT}/k8s/scripts/repair-minio-site-replication-k8s.sh"
      ;;
    emqx)
      bash "${SCRIPTS}/install-emqx.sh"
      ;;
    emqx-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/create-emqx-secret.sh"
      if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        sudo k3s kubectl apply -k "${INFRA_ROOT}/k8s/emqx"
      else
        kubectl apply -k "${INFRA_ROOT}/k8s/emqx"
      fi
      bash "${SCRIPTS}/ufw-allow-k3s-pods.sh" 2>/dev/null || true
      bash "${SCRIPTS}/sync-emqx-prometheus-targets.sh" 2>/dev/null || true
      ;;
    migrate-emqx-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/migrate-emqx-docker-to-k8s.sh"
      ;;
    mongodb)
      bash "${SCRIPTS}/install-mongodb.sh"
      ;;
    mongodb-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/create-mongodb-secret.sh"
      if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        sudo k3s kubectl apply -k "${INFRA_ROOT}/k8s/mongodb"
      else
        kubectl apply -k "${INFRA_ROOT}/k8s/mongodb"
      fi
      bash "${SCRIPTS}/ufw-allow-k3s-pods.sh" 2>/dev/null || true
      ;;
    migrate-mongodb-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/migrate-mongodb-docker-to-k8s.sh"
      ;;
    repair-mongodb-exporters)
      bash "${INFRA_ROOT}/k8s/scripts/repair-mongodb-exporter-host.sh"
      ;;
    ollama)
      bash "${SCRIPTS}/install-ollama.sh"
      ;;
    ollama-gateway)
      bash "${SCRIPTS}/install-ollama-gateway.sh"
      ;;
    repair-ollama-monitoring)
      bash "${SCRIPTS}/repair-ollama-monitoring.sh"
      ;;
    ollama-warmup-metrics)
      bash "${SCRIPTS}/ollama-warmup-metrics.sh"
      ;;
    mongodb-tls)
      # Par défaut HAProxy (Stunnel Mongo était cassé / ECONNRESET).
      if [[ "${FORCE_STUNNEL_MONGODB_TLS:-}" == "1" ]]; then
        bash "${SCRIPTS}/install-mongodb-tls.sh"
      else
        bash "${SCRIPTS}/install-haproxy.sh"
      fi
      ;;
    haproxy)
      bash "${SCRIPTS}/install-haproxy.sh"
      ;;
    haproxy-proxy)
      bash "${SCRIPTS}/install-haproxy-proxy.sh"
      ;;
    repair-haproxy)
      bash "${SCRIPTS}/repair-haproxy.sh"
      ;;
    mongodb-admin)
      bash "${SCRIPTS}/install-mongodb-admin.sh"
      ;;
    neo4j-admin)
      bash "${SCRIPTS}/install-neo4j-admin.sh"
      ;;
    repair-neo4j-admin)
      bash "${SCRIPTS}/repair-neo4j-admin.sh"
      ;;
    mongodb-backup)
      bash "${SCRIPTS}/install-mongodb-backup.sh"
      ;;
    mongodb-cloud-backup)
      bash "${SCRIPTS}/install-mongodb-cloud-backup.sh"
      ;;
    mongodb-cloud-tools)
      bash "${SCRIPTS}/install-mongodb-cloud-tools.sh"
      ;;
    repair-mongodb-prometheus)
      bash "${SCRIPTS}/repair-mongodb-prometheus.sh"
      ;;
    repair-neo4j-prometheus)
      bash "${SCRIPTS}/repair-neo4j-prometheus.sh"
      ;;
    repair-mongodb-replicaset)
      bash "${SCRIPTS}/repair-mongodb-replicaset.sh"
      ;;
    repair-mongodb-admin)
      bash "${SCRIPTS}/repair-mongodb-admin.sh"
      ;;
    repair-mongodb-tls)
      bash "${SCRIPTS}/repair-mongodb-tls.sh"
      ;;
    rename-mongodb-database)
      bash "${SCRIPTS}/rename-mongodb-database.sh"
      ;;
    emqx-broker)
      bash "${SCRIPTS}/install-emqx-broker.sh"
      ;;
    emqx-worker)
      bash "${SCRIPTS}/install-emqx-worker.sh"
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
    verify-minio-ops)
      bash "${SCRIPTS}/verify-minio-ops.sh"
      ;;
    repair-emqx-prometheus)
      bash "${SCRIPTS}/repair-emqx-prometheus.sh"
      ;;
    repair-emqx-boot)
      bash "${SCRIPTS}/repair-emqx-boot.sh"
      ;;
    repair-emqx-cluster)
      bash "${SCRIPTS}/repair-emqx-cluster.sh"
      ;;
    repair-emqx-auth)
      bash "${SCRIPTS}/repair-emqx-auth.sh"
      ;;
    repair-nginx-stream)
      bash "${SCRIPTS}/repair-nginx-stream.sh"
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
      # Legacy Docker Compose uniquement — sous k8s utiliser repair-minio-site-replication-k8s
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
    api-tls)
      bash "${INFRA_ROOT}/k8s/scripts/enable-api-nginx-ssl.sh"
      ;;
    ws-tls)
      bash "${INFRA_ROOT}/k8s/scripts/enable-ws-nginx-ssl.sh"
      ;;
    stunnel)
      bash "${SCRIPTS}/install-stunnel.sh"
      ;;
    tls)
      bash "${SCRIPTS}/install-certbot.sh"
      bash "${SCRIPTS}/install-haproxy.sh"
      ;;
    verify-tls)
      bash "${SCRIPTS}/verify-tls.sh"
      ;;
    verify-ipv6-endpoints)
      bash "${SCRIPTS}/verify-ipv6-endpoints.sh"
      ;;
    repair-ipv6-ufw)
      bash "${SCRIPTS}/repair-ipv6-ufw.sh"
      ;;
    monitoring)
      bash "${SCRIPTS}/install-monitoring.sh"
      ;;
    loki)
      bash "${SCRIPTS}/install-loki.sh"
      ;;
    repair-monitoring)
      bash "${SCRIPTS}/repair-monitoring.sh"
      ;;
    repair-prometheus-host-targets)
      bash "${SCRIPTS}/repair-prometheus-host-targets.sh"
      ;;
    repair-grafana-stack)
      bash "${SCRIPTS}/repair-grafana-stack.sh"
      ;;
    repair-cadvisor)
      bash "${SCRIPTS}/repair-cadvisor.sh"
      ;;
    repair-docker-daemon-cadvisor)
      bash "${SCRIPTS}/repair-docker-daemon-cadvisor.sh"
      ;;
    reset-grafana-dashboards-git)
      bash "${SCRIPTS}/reset-grafana-dashboards-git.sh"
      ;;
    grafana-console)
      bash "${SCRIPTS}/install-grafana-console.sh"
      ;;
    matomo)
      bash "${SCRIPTS}/install-matomo.sh"
      ;;
    neo4j)
      bash "${SCRIPTS}/install-neo4j.sh"
      ;;
    neo4j-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/create-neo4j-secret.sh"
      if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
        sudo k3s kubectl apply -k "${INFRA_ROOT}/k8s/neo4j"
      else
        kubectl apply -k "${INFRA_ROOT}/k8s/neo4j"
      fi
      bash "${SCRIPTS}/ufw-allow-k3s-pods.sh" 2>/dev/null || true
      ;;
    migrate-neo4j-k8s)
      bash "${INFRA_ROOT}/k8s/scripts/migrate-neo4j-docker-to-k8s.sh"
      ;;
    repair-neo4j-exporters)
      bash "${INFRA_ROOT}/k8s/scripts/repair-neo4j-exporter-host.sh"
      ;;
    matomo-gateway)
      bash "${SCRIPTS}/install-matomo-gateway.sh"
      ;;
    update-matomo)
      bash "${SCRIPTS}/update-matomo.sh"
      ;;
    repair-matomo)
      bash "${SCRIPTS}/repair-matomo.sh"
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
      bash "${SCRIPTS}/install-emqx.sh"
      bash "${SCRIPTS}/install-mongodb.sh"
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
