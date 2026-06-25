# africa-meals-infra

Infra VPS Wise Eat : Redis, Memcached, MinIO, EMQX, nginx/apache, Certbot, Stunnel, monitoring.

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
emqx/
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
sudo ./install.sh emqx

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
| `cache.wise-eat.com` | **80** (ACME) + **6381–6386** (Redis TLS) + **11212** (Memcached TLS) | Stunnel | **6381–6386/11212 en DNS only** (pas de proxy orange) |
| `console.wise-eat.com` | 80 / 443 | Grafana | proxy OK ou tunnel |
| `logs.wise-eat.com` | 80 / 443 | Prometheus (basic auth nginx) | proxy OK |
| `storage.wise-eat.com` | 80 / 443 | MinIO S3 API (médias) | proxy OK — uploads >100 Mo : DNS only |
| `cdn.wise-eat.com` | 80 / 443 | MinIO Console (basic auth nginx) | proxy OK |
| `broker.wise-eat.com` | **80** (ACME) + **8883** (MQTTS) + **8884** (WSS) | EMQX MQTT | **8883/8884 en DNS only** (pas de proxy orange) |
| `worker.wise-eat.com` | 80 / 443 | EMQX Dashboard (basic auth nginx) | proxy OK |

Après `./install.sh tls`, les apps peuvent utiliser `rediss://…@cache.wise-eat.com:6381` **sans** `REDIS_TLS_REJECT_UNAUTHORIZED=false`.

Sur le **VPS** (PM2 WS), Redis reste en local : `127.0.0.1:6379` / `:6380` sans TLS.

### IPv6 / dual-stack (accès VPS si IPv4 bloquée)

Si votre FAI ou le VPS bloque l’accès **IPv4** depuis votre poste, ajoutez des enregistrements **AAAA** Cloudflare (DNS only sur les ports non-HTTP) :

| Hostname | A (IPv4) | AAAA (IPv6 VPS) | Proxy CF |
|----------|----------|-----------------|----------|
| `cache.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | **DNS only** (:6381–6386, :11212) |
| `broker.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | **DNS only** (:8883, :8884) |
| `storage.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | Proxy OK (HTTPS) ou DNS only si uploads >100 Mo |
| `dr1-storage` / `dr2-storage` | conserver | `2a02:4780:75:447e::1` | DNS only |

**Côté apps (API, WS, mobile)** : aucun changement — garder les **hostnames** dans `.env` (`cache.wise-eat.com`, `broker.wise-eat.com`). Le client résout AAAA automatiquement.

**Sur le VPS** (une fois les AAAA publiés) :

```bash
cd /opt/wise-eat
git pull
sudo ./install.sh repair-ipv6-ufw
# ou manuellement :
sudo ./scripts/repair-ipv6-ufw.sh
sudo ./scripts/repair-vps-mqtt-broker-hosts.sh   # ajoute ::1 broker.wise-eat.com (hairpin PM2)
```

**Depuis votre Mac** (vérification) :

```bash
cd infra
chmod +x scripts/verify-ipv6-endpoints.sh
./scripts/verify-ipv6-endpoints.sh
```

Détails techniques :
- nginx écoute déjà en dual-stack (`listen [::]:443`, `[::]:8883`, …).
- Stunnel écoute en **v4 + v6** : `accept = PORT` (0.0.0.0) + `accept = :::PORT` (::) dans `redis/stunnel/*.conf` (syntaxe stunnel4, **pas** `[::]:PORT`).
- UFW doit avoir `IPV6=yes` (`/etc/default/ufw`) — activé par `repair-ipv6-ufw`.
- Variable optionnelle : `VPS_IPV6_ADDR=2a02:4780:75:447e::1` (défaut dans `scripts/lib/common.sh`).

> **Ne pas** remplacer les hostnames par l’adresse IPv6 dans `.env` — le certificat TLS (SNI) et la rotation DNS en dépendent.

> **Ne pas** proxifier Cloudflare les ports Redis/MQTT (6381–6386, 8883–8884) — proxy orange = HTTP(S) uniquement.

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
| `EMQX_BROKER_DOMAIN` | `broker.wise-eat.com` | MQTT public (nginx TLS) |
| `EMQX_MQTTS_PORT` | `8883` | MQTTS (nginx stream → EMQX :1883) |
| `EMQX_WSS_PORT` | `8884` | WSS (nginx → EMQX :8083/mqtt) |
| `EMQX_WORKER_DOMAIN` | `worker.wise-eat.com` | Dashboard EMQX public (nginx + basic auth) |
| `MINIO_BACKUP_DIR` | `/var/backups/wise-eat-minio` | Sauvegardes incrémentales (hors volume 25G) |
| `VPS_IPV6_ADDR` | `2a02:4780:75:447e::1` | IPv6 publique VPS (AAAA Cloudflare) |
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
| `stunnel` | Redis TLS :6381–6386 (primary + réplicas cluster-b, cert LE requis) |
| `tls` | certbot + stunnel |
| `verify-tls` | Contrôle certs LE + Stunnel |
| `redis` / `memcached` / `minio` / `emqx` / `emqx-broker` / `emqx-worker` / `minio-storage` / `minio-console` / `minio-backup` / `monitoring` / `permissions` | voir runbooks |

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

**EMQX** : dossier Grafana `EMQX/` avec **Wise Eat — EMQX** (base Grafana.com #17446) — scrape `job=emqx` sur `/api/v5/prometheus/stats` (primary + réplicas).

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

| Service | Primary (local) | Réplica 1 | Réplica 2 | Stunnel TLS (remote) |
|---------|-----------------|-----------|-----------|----------------------|
| Redis cache | `:6379` | `:6371` | `:6372` | `:6381` / `:6383` / `:6384` |
| Redis BullMQ | `:6380` | `:6390` | `:6391` | `:6382` / `:6385` / `:6386` |
| Memcached | `:11211` | `:11213` | `:11214` | `:11212` (primary) |

```bash
cd /opt/wise-eat
git pull
sudo ./install.sh redis
sudo ./install.sh memcached
sudo ./install.sh repair-monitoring
```

- `redis/.env.redis` : `REDIS_CLUSTER_B_ENABLED=true`
- `memcached/.env.memcached` : `MEMCACHED_CLUSTER_B_ENABLED=true`

**Remote (Mac / Cloud Functions → VPS)** — primary + réplicas via Stunnel :

```env
REDIS_URL=rediss://wise-eat-cache:<password>@cache.wise-eat.com:6381
REDIS_REPLICA_1_URL=rediss://wise-eat-cache:<password>@cache.wise-eat.com:6383
REDIS_REPLICA_2_URL=rediss://wise-eat-cache:<password>@cache.wise-eat.com:6384
BULLMQ_REDIS_URL=rediss://wise-eat-bull:<password>@cache.wise-eat.com:6382
BULLMQ_REDIS_REPLICA_1_URL=rediss://wise-eat-bull:<password>@cache.wise-eat.com:6385
BULLMQ_REDIS_REPLICA_2_URL=rediss://wise-eat-bull:<password>@cache.wise-eat.com:6386
REDIS_TLS=true
REDIS_TLS_REJECT_UNAUTHORIZED=true
```

**Redis** : les 2 réplicas répliquent le primary (async). Failover manuel (VPS local) :

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

DNS A (ou CNAME) requis pour `dr1-storage.wise-eat.com` et `dr2-storage.wise-eat.com` → même VPS.

TLS réplicas (certificats LE dédiés — requis pour `MINIO_REPLICA_ENDPOINTS` HTTPS) :
```bash
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh minio-replica-storage
```

> **Port 9000** : l’API Nest (`NODE_PORT=9000`) écoute sur `0.0.0.0:9000` ; MinIO sur `127.0.0.1:9000` uniquement. Prometheus scrape **wise-eat-minio:9000** via le réseau Docker — jamais `host:9000` (sinon 404 sur l’API).

## EMQX (MQTT)

Broker MQTT self-hosted (remplace EMQX Cloud / Mosquitto) — cluster **1 primary + 2 réplicas** sur le VPS.

```bash
sudo ./install.sh emqx
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh emqx-broker
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh emqx-worker
```

| Port / URL | Service |
|------------|---------|
| `mqtt://127.0.0.1:1883` | MQTT local (debug / repair scripts sur le VPS uniquement) |
| `ws://127.0.0.1:8083/mqtt` | WebSocket local (debug) |
| `http://127.0.0.1:18083` | Dashboard EMQX local (admin — voir `.env.emqx`) |
| `https://worker.wise-eat.com` | Dashboard EMQX public (basic auth nginx + login EMQX) |
| `mqtts://broker.wise-eat.com:8883` | MQTT TLS public (nginx → primary) — **dev + prod** |
| `wss://broker.wise-eat.com:8884/mqtt` | WebSocket TLS public — **dev + prod** |

**Utilisateurs MQTT** (créés par `bootstrap-emqx-auth.sh`) :

| User | Rôle | Variable mot de passe |
|------|------|------------------------|
| `wise-eat-mqtt` | WS subscriber | `MQTT_BROKER_PASSWORD` |
| `wise-eat-admin` | API publisher | `MQTT_ADMIN_PASSWORD` |

Secrets dans `emqx/.env.emqx` (générés à l’install).

**Dev + prod (Mac local, PM2 VPS, Cloud Functions)** — toujours via le **domaine**, pas l’IP :

```env
MQTT_BROKER_HOST=broker.wise-eat.com
MQTT_BROKER_PORT=8883
MQTT_BROKER_WS_PORT=8884
MQTT_BROKER_PROTOCOL=mqtts
MQTT_BROKER_URL=mqtts://broker.wise-eat.com:8883
MQTT_BROKER_WS_URL=wss://broker.wise-eat.com:8884/mqtt
MQTT_TOPIC_PREFIX=wiseeat/internal/ws
```

| App | Fichier env | `MQTT_BROKER_USERNAME` | Mot de passe |
|-----|-------------|------------------------|--------------|
| API (publisher) | `.env` / `.env.develop` | `wise-eat-admin` | `MQTT_ADMIN_PASSWORD` |
| WS (subscriber) | `.env` / `.env.develop` | `wise-eat-mqtt` | `MQTT_BROKER_PASSWORD` |

Après modification sur le VPS : `pm2 restart all --update-env` (ou les processus API/WS concernés).

**PM2 sur le VPS (hairpin NAT)** : depuis la machine elle-même, `broker.wise-eat.com` peut résoudre vers l’IP publique sans route retour. Les apps gardent le domaine dans `.env`, mais ajoutez une entrée loopback :

```bash
sudo ./scripts/repair-vps-mqtt-broker-hosts.sh
# équivalent manuel : echo "127.0.0.1 broker.wise-eat.com # wise-eat-emqx-broker-local" | sudo tee -a /etc/hosts
```

DNS A + AAAA `broker.wise-eat.com` → VPS (`2a02:4780:75:447e::1` en v6). Ports **8883** et **8884** : **DNS only** sur Cloudflare (comme Redis Stunnel).

DNS A `worker.wise-eat.com` → VPS (proxy Cloudflare OK pour le dashboard HTTPS).

**Accès dashboard public** : double authentification — basic auth nginx sur l’UI (`EMQX_WORKER_BASIC_AUTH_PASSWORD`, user `emqx-worker`) puis login EMQX (`admin` / `EMQX_DASHBOARD_PASSWORD`). Les appels `/api/` passent sans basic auth nginx (le dashboard EMQX utilise `Authorization: Bearer`, incompatible avec une double couche sur la même en-tête).

Cluster : **3 conteneurs toujours déployés** (`wise-eat-emqx-1` primary + `wise-eat-emqx-2/3` réplicas). Sessions/topics répliqués ; seul le primary expose `:1883/:8083/:18083` en local.

Si Docker Desktop n’affiche qu’**1 container** :
```bash
sudo ./install.sh repair-emqx-cluster
docker exec wise-eat-emqx-1 emqx ctl cluster status
```

**Grafana** : dossier **EMQX** → **Wise Eat — EMQX** (connexions, messages, packets, cluster, VM Erlang). Prérequis : EMQX installé + scrape Prometheus.

Panneau **System** (RAM, Mnesia, processus Erlang) :
- **RAM Total** : requête `node_memory_MemTotal_bytes` (node_exporter récent) avec repli `emqx_vm_total_memory`.
- **Mnesia / Erlang VM** : collecteurs `EMQX_PROMETHEUS__COLLECTORS__*` activés dans `emqx/docker-compose.yml` (`vm_memory`, `vm_system_info`, `vm_statistics`, `mnesia`).

Si Grafana affiche **No data** :
```bash
sudo ./install.sh repair-emqx-prometheus
```

Après une **recréation EMQX** (collecteurs Prometheus), le dashboard `worker.wise-eat.com` peut afficher **502** pendant ~2 min (healthcheck EMQX). Le script attend l’API avant de recharger nginx. En cas de 502 persistant :
```bash
curl -sf http://127.0.0.1:18083/api/v5/status && sudo ./install.sh emqx-worker
```
Recréation forcée des conteneurs EMQX (rare) : `EMQX_FORCE_RECREATE=1 sudo ./install.sh repair-emqx-prometheus`
