# africa-meals-infra

Infra VPS Wise Eat : Redis, Memcached, MinIO, nginx/apache, Certbot, Stunnel, monitoring.

## Structure

```
install.sh
scripts/
  install-nginx.sh      reverse-proxy WS + Certbot webroot
  install-apache.sh     idem Apache
  install-web.sh        WEB_SERVER=nginx|apache
  install-certbot.sh
  install-stunnel.sh
  enable-nginx-ssl.sh / enable-apache-ssl.sh
nginx/                  templates site wise-eat.cloud
apache/
redis/
memcached/
minio/
monitoring/
```

## Installation complète (VPS)

```bash
git clone https://github.com/AfrikanMeals/africa-meals-infra.git /opt/wise-eat
cd /opt/wise-eat
chmod +x install.sh scripts/*.sh

# 1. Redis
sudo ./install.sh redis

# 1b. Cache & stockage local (dev / VPS)
sudo ./install.sh memcached
sudo ./install.sh minio

# 2. Serveur web (un seul — nginx recommandé)
sudo ./install.sh nginx
# ou : sudo ./install.sh apache
# ou : sudo WEB_SERVER=apache ./install.sh web

# 3. TLS Let's Encrypt (WS + Redis Stunnel + Grafana)
sudo ./install.sh nginx
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls
sudo ./install.sh verify-tls

# 4. Monitoring
sudo ./install.sh monitoring
```

**Une commande** après nginx :

```bash
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls
sudo ./install.sh verify-tls
```

### Prérequis DNS (Certbot HTTP-01)

| Hostname | Port | Usage | Cloudflare |
|----------|------|-------|------------|
| `wise-eat.cloud` | 80 / 443 | WS nginx | proxy OK |
| `cache.wise-eat.com` | **80** (ACME) + **6381/6382** (Redis TLS) + **11212** (Memcached TLS) | Stunnel | **6381/6382/11212 en DNS only** (pas de proxy orange) |
| `console.wise-eat.com` | 80 / 443 | Grafana | proxy OK ou tunnel |
| `logs.wise-eat.com` | 80 / 443 | Prometheus (basic auth nginx) | proxy OK |
| `storage.wise-eat.com` | 80 / 443 | MinIO S3 API (médias) | proxy OK — uploads >100 Mo : DNS only |
| `cdn.wise-eat.com` | 80 / 443 | MinIO Console (basic auth nginx) | proxy OK |

Après `./install.sh tls`, les apps peuvent utiliser `rediss://…@cache.wise-eat.com:6381` **sans** `REDIS_TLS_REJECT_UNAUTHORIZED=false`.

Sur le **VPS** (PM2 WS), Redis reste en local : `127.0.0.1:6379` / `:6380` sans TLS.

> **nginx et apache** ne tournent pas ensemble sur le port 80 — l’install de l’un arrête l’autre.

## Variables

| Variable | Défaut | Rôle |
|----------|--------|------|
| `WISE_EAT_DOMAIN` | `wise-eat.cloud` | vhost WS + certificat |
| `REDIS_TLS_DOMAIN` | `cache.wise-eat.com` | certificat Stunnel Redis (:6381/:6382) |
| `GRAFANA_CONSOLE_DOMAIN` | `console.wise-eat.com` | Grafana public (nginx ou tunnel) |
| `PROMETHEUS_LOGS_DOMAIN` | `logs.wise-eat.com` | Prometheus public (nginx + basic auth) |
| `MINIO_STORAGE_DOMAIN` | `storage.wise-eat.com` | MinIO S3 public (nginx + TLS) |
| `MINIO_CONSOLE_DOMAIN` | `cdn.wise-eat.com` | MinIO Console public (nginx + basic auth) |
| `MINIO_STORAGE_GB` | `25` | Taille volume données MinIO (loop ext4) |
| `MINIO_DATA_DIR` | `/var/lib/wise-eat/minio` | Montage objets S3 |
| `MINIO_BACKUP_DIR` | `/var/backups/wise-eat-minio` | Sauvegardes incrémentales (hors volume 25G) |
| `WS_BACKEND_PORT` | `8000` | PM2 WS prod |
| `STUNNEL_TLS_EMAIL` | — | Let's Encrypt |
| `WEB_SERVER` | `nginx` | pour `./install.sh web` |

## Composants `install.sh`

| Composant | Description |
|-----------|-------------|
| `nginx` | Installe nginx, proxy → WS, webroot Certbot |
| `apache` | Installe apache2, proxy → WS, webroot Certbot |
| `web` | `WEB_SERVER=nginx\|apache` |
| `certbot` | LE : WS + Redis Stunnel + Grafana + Prometheus |
| `stunnel` | Redis TLS :6381/:6382 (cert LE requis en prod) |
| `tls` | certbot + stunnel |
| `verify-tls` | Contrôle certs LE + Stunnel |
| `redis` / `memcached` / `minio` / `minio-storage` / `minio-console` / `minio-backup` / `monitoring` / `permissions` | voir runbooks |

## Memcached

Cache applicatif (alternative à Redis pour `CACHE_STORE=memcached`).

```bash
sudo ./install.sh memcached
```

| Port | Service |
|------|---------|
| `11211` | Memcached (localhost) |
| `11212` | Memcached TLS (Stunnel → :11211) |

Variables API local : `MEMCACHED_SERVERS=127.0.0.1:11211`

Remote TLS (Cloud Functions / Mac → VPS) :

```env
MEMCACHED_SERVERS=cache.wise-eat.com:11212
MEMCACHED_TLS=true
```

Après `./install.sh stunnel` (cert LE sur `cache.wise-eat.com` requis).

Avec le stack monitoring : métriques via `memcached_exporter` sur `127.0.0.1:9150`, dashboard Grafana **Memcached**.

**Core System (VPS)** : dossier Grafana `Core System/` avec :
- **Wise Eat — System (Node Exporter)** (#1860) — `node_exporter` `:9100`, job `node`
- **Wise Eat — Docker Monitoring** (#4271) — `cAdvisor` `:8088`, job `cadvisor` (+ métriques `node_*` alignées sur instance `wise-eat:9100`)

**MinIO** : dossier Grafana `MinIO/` avec **Wise Eat — MinIO Storage** (équivalent Prometheus du #20826) — scrape `minio-cluster` + `minio-node`.

Les variables **Job / Nodename / Instance** (System) et **Node / Compose project** (Docker) restent vides tant que les exporters ne sont pas scrapés (`sudo ./install.sh repair-monitoring`).

#### Grafana vide (Redis DOWN / Memcached DOWN / No data)

Cause fréquente : les exporters Docker ne joignaient pas Redis/Memcached car ces services n’écoutent que sur `127.0.0.1` (inaccessible via `host.docker.internal`). Le stack utilise désormais le réseau Docker partagé `wise-eat-infra`.

Sur le VPS (dépôt cloné dans `/opt/wise-eat`, pas `/opt/wise-eat/infra`) :

```bash
cd /opt/wise-eat
git pull
sudo ./install.sh repair-monitoring
```

Ou étape par étape :

```bash
cd /opt/wise-eat
sudo ./install.sh redis
sudo ./install.sh memcached
sudo ./install.sh repair-monitoring
```

```bash
curl -s http://127.0.0.1:9121/metrics | grep '^redis_up '
curl -s http://127.0.0.1:9150/metrics | grep '^memcached_up '
curl -s http://127.0.0.1:9100/metrics | grep '^node_cpu_seconds_total' | head -1
curl -s http://127.0.0.1:8088/metrics | grep '^container_cpu_usage_seconds_total' | head -1
curl -s 'http://127.0.0.1:9090/api/v1/query?query=node_uname_info'
```

Attendu : `redis_up 1` et `memcached_up 1`. Si `redis_up 0`, aligner `CACHE_REDIS_PASSWORD` / `BULL_REDIS_PASSWORD` entre `redis/.env.redis` et `monitoring/.env.monitoring`, puis relancer `repair-monitoring`.

## Multi-clusters (même VPS) — 1 primary + 2 réplicas

| Service | Primary | Réplica 1 | Réplica 2 |
|---------|---------|-----------|-----------|
| Redis cache | `:6379` | `:6371` | `:6372` |
| Redis BullMQ | `:6380` | `:6390` | `:6391` |
| Memcached | `:11211` | `:11213` | `:11214` |

```bash
cd /opt/wise-eat
git pull
sudo ./install.sh redis
sudo ./install.sh memcached
sudo ./install.sh repair-monitoring
```

- `redis/.env.redis` : `REDIS_CLUSTER_B_ENABLED=true`
- `memcached/.env.memcached` : `MEMCACHED_CLUSTER_B_ENABLED=true`

**Redis** : les 2 réplicas répliquent le primary (async). Failover manuel :

```env
REDIS_PORT=6371
BULLMQ_REDIS_PORT=6390
```

**Memcached** : pas de réplication native — les 2 réplicas sont des **pools standby** (bascule manuelle vers `:11213` ou `:11214`). Ne pas lister les 3 pools en même temps sauf sharding voulu.

> 1 VPS = pas de HA si la machine tombe entièrement.

### Grafana public (`console.wise-eat.com`)

| Mode | Commande |
|------|----------|
| **Cloudflare Tunnel** (Mac / dev) | Voir `docs/CLOUDFLARED.md` + `cloudflared/config.example.yml` |
| **VPS nginx + TLS** | `sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh grafana-console` |

Dans `monitoring/.env.monitoring` : `GRAFANA_ROOT_URL=https://console.wise-eat.com/` puis `docker compose up -d` (recréer Grafana).

### Prometheus public (`logs.wise-eat.com`)

Prometheus n’a pas d’auth native : protection via **nginx basic auth** + TLS.

| Mode | Commande |
|------|----------|
| **VPS nginx + TLS** | `sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh prometheus-logs` |

Le mot de passe basic auth est dans `monitoring/.env.monitoring` (`PROMETHEUS_BASIC_AUTH_USER` / `PROMETHEUS_BASIC_AUTH_PASSWORD`), généré par `./install.sh monitoring` si absent.

Dans `monitoring/.env.monitoring` : `PROMETHEUS_EXTERNAL_URL=https://logs.wise-eat.com/` puis :

```bash
cd monitoring && docker compose --env-file .env.monitoring up -d --force-recreate prometheus
```

## MinIO

Stockage S3-compatible pour médias (`STORAGE_ENGINE=minio`).

```bash
sudo ./install.sh minio
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh minio-storage
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh minio-console
```

| Port / URL | Service |
|------------|---------|
| `https://storage.wise-eat.com` | API S3 publique (nginx + TLS) |
| `https://cdn.wise-eat.com` | Console MinIO (nginx + TLS + basic auth) |
| `127.0.0.1:9000` | API locale (PM2 sur le VPS) |
| `127.0.0.1:9001` | Console locale (debug) |

**Console publique** (`cdn.wise-eat.com`) — double authentification :
1. **Popup navigateur (nginx basic auth)** : utilisateur `minio-console` — mot de passe **`MINIO_CONSOLE_BASIC_AUTH_PASSWORD`** dans `minio/.env.minio` (pas les identifiants MinIO)
2. **Formulaire MinIO** : `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`

Si la popup basic auth se répète en boucle : `sudo ./install.sh minio-console` (resynchronise nginx + htpasswd).

**Volume 25 Go** : loop ext4 `/var/lib/wise-eat/minio-data.img` monté sur `/var/lib/wise-eat/minio` (ou `MINIO_DATA_DEVICE` pour un disque dédié).

**Sauvegardes incrémentales** :
- Mirror quotidien (`mc mirror`) → `/var/backups/wise-eat-minio/latest/`
- Snapshot hebdomadaire (hardlinks rsync, dimanche)
- Rétention 30 jours (`MINIO_BACKUP_RETENTION_DAYS`)
- Cron : `03:00` — logs `/var/log/wise-eat-minio-backup.log`

```bash
sudo ./install.sh minio-backup    # installer / réinstaller le cron
sudo ./scripts/backup-minio.sh    # test manuel
```

Secrets générés dans `minio/.env.minio`. Le script crée le bucket `wise-eat` et affiche les variables `MINIO_*` pour l’API.

MinIO rejoint le réseau Docker `wise-eat-infra` pour le scrape Prometheus (`job: minio`). Grafana : dossier **MinIO** → dashboard **Wise Eat — MinIO Storage**.

**API prod** (`africa-meals-api/.env`) :
```env
MINIO_ENDPOINT=https://storage.wise-eat.com
MINIO_PUBLIC_BASE_URL=https://storage.wise-eat.com/wise-eat
MINIO_REPLICA_ENDPOINTS=https://dr1-storage.wise-eat.com,https://dr2-storage.wise-eat.com
MINIO_FORCE_PATH_STYLE=true
```

DNS A (ou CNAME) requis pour `dr1-storage.wise-eat.com` et `dr2-storage.wise-eat.com` → même VPS. `install.sh minio-replication` configure nginx + TLS (Certbot si `STUNNEL_TLS_EMAIL` défini).

> **Port 9000** : l’API Nest (`NODE_PORT=9000`) écoute sur `0.0.0.0:9000` ; MinIO sur `127.0.0.1:9000` uniquement. Prometheus scrape **wise-eat-minio:9000** via le réseau Docker — jamais `host:9000` (sinon 404 sur l’API).
