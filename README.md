# africa-meals-infra

Infra VPS Wise Eat : Redis, Memcached, MinIO, EMQX, MongoDB, Neo4j (optionnel), nginx/apache, Certbot, **HAProxy** (TLS TCP), monitoring.

## Structure

```
install.sh
stop.sh                 # arrêt par composant (sudo ./stop.sh redis|neo4j|…)
scripts/
  install-nginx.sh      reverse-proxy WS + Certbot webroot
  install-apache.sh     idem Apache
  install-web.sh        WEB_SERVER=nginx|apache
  install-certbot.sh
  install-haproxy.sh    TLS TCP Mongo/Redis/Memcached + UI proxy.wise-eat.com
  install-stunnel.sh    legacy (préférer haproxy)
  enable-nginx-ssl.sh / enable-apache-ssl.sh
nginx/                  templates (console, proxy, storage, …)
haproxy/                haproxy.cfg + README
apache/
redis/
memcached/
minio/
emqx/
monitoring/
ollama/
matomo/
neo4j/
```

## Arrêt par composant

```bash
cd /opt/wise-eat
chmod +x stop.sh
sudo ./stop.sh --list
sudo ./stop.sh neo4j              # compose stop (données conservées)
sudo ./stop.sh redis memcached
STOP_MODE=down sudo ./stop.sh ollama   # compose down --remove-orphans (sans -v)
sudo ./stop.sh k8s-api            # scale deployment → 0
```

Relancer ensuite avec `sudo ./install.sh <composant>` (ou le script k8s de déploiement pour l’API/WS).

## Installation complète (VPS)

```bash
git clone https://github.com/AfrikanMeals/africa-meals-infra.git /opt/wise-eat
cd /opt/wise-eat
chmod +x install.sh stop.sh scripts/*.sh

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

# 3. TLS Let's Encrypt (WS + HAProxy Redis/Mongo/Memcached + UI proxy)
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
| `cache.wise-eat.com` | **80** (ACME) + **6381–6386** (Redis TLS) + **11212** (Memcached TLS) | HAProxy | **6381–6386/11212 en DNS only** (pas de proxy orange) |
| `proxy.wise-eat.com` | 80 / 443 | HAProxy Stats UI (basic auth) | proxy OK |
| `console.wise-eat.com` | 80 / 443 | Grafana | proxy OK ou tunnel |
| `logs.wise-eat.com` | 80 / 443 | Prometheus (basic auth nginx) | proxy OK |
| `storage.wise-eat.com` | 80 / 443 | MinIO S3 API (médias) | proxy OK — uploads >100 Mo : DNS only |
| `cdn.wise-eat.com` | 80 / 443 | MinIO Console (basic auth nginx) | proxy OK |
| `broker.wise-eat.com` | **80** (ACME) + **8883** (MQTTS) + **8884** (WSS) | EMQX MQTT | **8883/8884 en DNS only** (pas de proxy orange) |
| `worker.wise-eat.com` | 80 / 443 | EMQX Dashboard (basic auth nginx) | proxy OK |
| `db.wise-eat.com` | **80** (ACME) + **27018** (MongoDB TLS) | HAProxy → primary | **27018 en DNS only** (pas de proxy orange) |
| `data.wise-eat.com` | 80 / 443 | DbGate admin MongoDB (basic auth nginx) | proxy OK |
| `db-graph.wise-eat.com` | 80 / 443 + **7688** (Bolt TLS) | Neo4j Browser (basic auth) + Bolt | **443 proxy OK** ; **7688 DNS only** |
| `ai.wise-eat.com` | 80 / 443 | Ollama API (basic auth nginx, dual-stack) | proxy OK (A + AAAA) |
| `analytics.wise-eat.com` | 80 / 443 | Matomo Analytics (self-hosted) | proxy OK |

Après `./install.sh tls`, les apps peuvent utiliser `rediss://…@cache.wise-eat.com:6381` **sans** `REDIS_TLS_REJECT_UNAUTHORIZED=false`.

Sur le **VPS** (PM2 WS), Redis reste en local : `127.0.0.1:6379` / `:6380` sans TLS.

Voir aussi : [haproxy/README.md](haproxy/README.md).

### IPv6 / dual-stack (accès VPS si IPv4 bloquée)

Si votre FAI ou le VPS bloque l’accès **IPv4** depuis votre poste, ajoutez des enregistrements **AAAA** Cloudflare (DNS only sur les ports non-HTTP) :

| Hostname | A (IPv4) | AAAA (IPv6 VPS) | Proxy CF |
|----------|----------|-----------------|----------|
| `cache.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | **DNS only** (:6381–6386, :11212) |
| `broker.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | **DNS only** (:8883, :8884) |
| `storage.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | Proxy OK (HTTPS) ou DNS only si uploads >100 Mo |
| `ai.wise-eat.com` | conserver | `2a02:4780:75:447e::1` | Proxy OK (HTTPS Ollama gateway) |
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
- Limite connexions : Stunnel 5.x calcule `max_clients = max_fds×125/256` (défaut ulimit 1024 → **500**). Augmenter via `RLIMITS=-n` dans `/etc/default/stunnel4` (défaut **5000** clients via `STUNNEL_MAX_CLIENTS`). Si journal `too many clients (>=500)` → `sudo STUNNEL_MAX_CLIENTS=5000 ./install.sh stunnel`.
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
| `STUNNEL_MAX_CLIENTS` | `5000` | limite globale connexions TLS (défaut binaire = **500**) |
| `STUNNEL_TIMEOUT_IDLE` | `0` | idle Stunnel (secondes) ; `0` = garder ouvert (drivers Mongo/Redis) |
| `GRAFANA_CONSOLE_DOMAIN` | `console.wise-eat.com` | Grafana public (nginx ou tunnel) |
| `PROMETHEUS_LOGS_DOMAIN` | `logs.wise-eat.com` | Prometheus public (nginx + basic auth) |
| `MINIO_STORAGE_DOMAIN` | `storage.wise-eat.com` | MinIO S3 public (nginx + TLS) |
| `MINIO_CONSOLE_DOMAIN` | `cdn.wise-eat.com` | MinIO Console public (nginx + basic auth) |
| `MINIO_STORAGE_GB` | `10` | Taille volume données MinIO (loop ext4) |
| `MINIO_DATA_DIR` | `/var/lib/wise-eat/minio` | Montage objets S3 |
| `EMQX_BROKER_DOMAIN` | `broker.wise-eat.com` | MQTT public (nginx TLS) |
| `EMQX_MQTTS_PORT` | `8883` | MQTTS (nginx stream → EMQX :1883) |
| `EMQX_WSS_PORT` | `8884` | WSS (nginx → EMQX :8083/mqtt) |
| `EMQX_WORKER_DOMAIN` | `worker.wise-eat.com` | Dashboard EMQX public (nginx + basic auth) |
| `MONGO_TLS_DOMAIN` | `db.wise-eat.com` | MongoDB TLS public (Stunnel :27018) |
| `MONGO_TLS_PORT` | `27018` | Port TLS MongoDB (Stunnel → primary :27017) |
| `MONGO_ADMIN_DOMAIN` | `data.wise-eat.com` | DbGate admin MongoDB (nginx + basic auth) |
| `NEO4J_ADMIN_DOMAIN` | `db-graph.wise-eat.com` | Neo4j Browser public (nginx + basic auth) + Bolt TLS :7688 |
| `OLLAMA_GATEWAY_DOMAIN` | `ai.wise-eat.com` | Ollama API public (nginx + basic auth) |
| `MATOMO_DOMAIN` | `analytics.wise-eat.com` | Matomo Analytics public (nginx + TLS) |
| `MATOMO_HTTP_PORT` | `8089` | Matomo local (127.0.0.1 uniquement) |
| `MATOMO_STORAGE_GB` | `5` | Taille volume données Matomo (loop ext4) |
| `MATOMO_DATA_DIR` | `/var/lib/wise-eat/matomo` | Données Matomo + MariaDB |
| `MONGO_STORAGE_GB` | `5` | Taille volume données MongoDB (loop ext4) |
| `MINIO_BACKUP_DIR` | `/var/backups/wise-eat-minio` | Sauvegardes incrémentales (hors volume 10G) |
| `VPS_IPV6_ADDR` | `2a02:4780:75:447e::1` | IPv6 publique VPS (AAAA Cloudflare) |
| `WS_WISE_EAT_DOMAIN` | `ws.wise-eat.com` | vhost HTTPS/WSS WS k8s (NodePort 30800) |
| `WS_BACKEND_PORT` | `30800` | NodePort k3s WS prod (PM2 dev : 8000 — voir `k8s/DEPLOY.md`) |
| `STUNNEL_TLS_EMAIL` | — | Let's Encrypt |
| `WEB_SERVER` | `nginx` | pour `./install.sh web` |
| `VPS_SWAP_SIZE_GB` | `2` | Swap hôte (créé par `ensure_vps_swap` si absent) |
| `VPS_SWAPPINESS` | `40` | Aggressivité swap kernel (0–100) |

## Mémoire & swap (VPS 8 Go)

Profil cible : **2 vCPU / 8 Go RAM / 2 Go swap**. Chaque conteneur a un `mem_limit` (RAM) et un `memswap_limit` (RAM + swap autorisé) :

| Composant | RAM | Swap conteneur | Total cgroup |
|-----------|-----|----------------|--------------|
| MongoDB ×3 | 512 Mo | 512 Mo | 1 Go |
| DbGate | 512 Mo | 256 Mo | 768 Mo |
| Ollama | 3 Go | 1 Go | 4 Go |
| EMQX ×3 | 256 Mo | 128 Mo | 384 Mo |
| Prometheus | 512 Mo | 256 Mo | 768 Mo |
| Grafana | 256 Mo | 128 Mo | 384 Mo |
| Redis cache (+ réplicas) | 896 Mo | 256 Mo | 1152 Mo |
| Redis BullMQ (+ réplicas) | 640 Mo | 128 Mo | 768 Mo |
| Memcached ×3 | 192 Mo | 64 Mo | 256 Mo |
| MinIO | 256 Mo | 128 Mo | 384 Mo |
| Matomo + MariaDB | 640 Mo | 256 Mo | 896 Mo |

Le swap hôte est provisionné automatiquement à chaque `install.sh` (via `ensure_docker` → `scripts/lib/vps-swap.sh`). Vérification :

```bash
swapon --show
sysctl vm.swappiness
docker inspect wise-eat-mongo-1 --format 'mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}'
```

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
| `redis` / `memcached` / `minio` / `emqx` / `ollama` / `ollama-gateway` / `emqx-broker` / `emqx-worker` / `minio-storage` / `minio-console` / `minio-backup` / `monitoring` / `permissions` | voir runbooks |

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

## Ollama (embeddings + copy LLM)

Stack AI local pour recherche sémantique (`nomic-embed-text`) et génération de copy push/newsletter (`llama3.2:3b`).

**Profil VPS cible** : 2 vCPU / 8 Go RAM (CPU-only, pas de GPU). Réglages par défaut dans `ollama/.env.example` :

| Variable | Valeur | Rôle |
|----------|--------|------|
| `OLLAMA_MEM_LIMIT` | `3g` | Suffisant pour `llama3.2:3b` (~2 Go) ; laisse de la RAM à Mongo/EMQX/WS |
| `OLLAMA_CPU_LIMIT` | `1.5` | Réserve ~0,5 vCPU au reste du stack pendant l’inférence |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Un seul modèle en RAM (embeddings **ou** copy, pas les deux) |
| `OLLAMA_NUM_PARALLEL` | `1` | Une inférence à la fois |
| `OLLAMA_MAX_QUEUE` | `8` | Évite une file de 512 requêtes sur un petit VPS |
| `OLLAMA_KEEP_ALIVE` | `2m` | Décharge le modèle plus vite après idle |
| `OLLAMA_CONTEXT_LENGTH` | `1024` | Contexte court (copy + embeddings) → moins de RAM KV cache |

**Prérequis DNS** : `ai.wise-eat.com` → A + AAAA vers le VPS (proxy Cloudflare OK pour :443).

```bash
cd /opt/wise-eat
git pull
sudo ./install.sh ollama
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh ollama-gateway
# ou renouveler tous les certs :
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot
```

| Port | Service |
|------|---------|
| `11434` | Ollama API (localhost uniquement) |
| `443` | Gateway public `https://ai.wise-eat.com` (nginx + basic auth, IPv4/IPv6) |

**API locale** (PM2 africa-meals-api sur le VPS — sans auth) :

```env
OLLAMA_BASE_URL=http://127.0.0.1:11434
```

**API distante** (Mac / Cloud Functions — basic auth nginx) :

```env
OLLAMA_BASE_URL=https://ai.wise-eat.com
# + Authorization: Basic … (voir ollama/.env.ollama OLLAMA_GATEWAY_BASIC_AUTH_*)
```

Modèles (re-téléchargement) :

```bash
sudo ./scripts/pull-ollama-models.sh
```

Grafana : **[Ollama LLM Inference](https://grafana.com/grafana/dashboards/25086-ollama-llm-inference/)** (#25086) — métriques via [ollama-exporter](https://github.com/maravexa/ollama-exporter) (`job=ollama`, `:9400`).

| Port | Rôle |
|------|------|
| `9400` | Métriques Prometheus (`/metrics`) |
| `9401` | Proxy transparent (optionnel — pour TPS/latence requêtes ; pointer `OLLAMA_BASE_URL` ici sur le VPS) |

Si Grafana Ollama affiche **No data** :

```bash
sudo ./install.sh repair-ollama-monitoring
curl -s http://127.0.0.1:9400/metrics | grep '^ollama_up '

# Remplir VRAM + métriques requêtes (première fois ou après idle)
sudo ./install.sh ollama-warmup-metrics
```

**Comportement normal** : seul **Ollama Status = UP** tant qu'aucun modèle n'est en VRAM (`/api/ps` vide) et que l'API n'utilise pas le proxy `:9401`. Les panels TPS/latence/requêtes nécessitent `OLLAMA_BASE_URL=http://127.0.0.1:9401` sur le VPS.

## Matomo Analytics (self-hosted)

[Matomo On-Premise](https://matomo.org/matomo-on-premise/) — analytics web first-party, données hébergées sur le VPS Wise Eat (MariaDB + Apache Docker, ~640 Mo RAM).

```bash
# DNS : A/AAAA analytics.wise-eat.com → VPS (proxy Cloudflare OK)

sudo ./install.sh nginx          # si pas déjà fait
sudo ./install.sh matomo
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh matomo-gateway
# ou certificat global :
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot
sudo ./install.sh verify-tls
```

| Port | Rôle |
|------|------|
| `8089` | Matomo HTTP local (`127.0.0.1` — nginx reverse-proxy public) |

Première visite : créer le compte super utilisateur dans l'assistant Matomo, puis vérifier **Administration → Système → Général** : URL = `https://analytics.wise-eat.com/` et HTTPS activé.

Secrets : `matomo/.env.matomo` (chmod 600, généré au premier `install.sh matomo`).

## Neo4j (self-hosted, optionnel)

Graphe de recommandation / similarité — **pas** la SoT (Mongo reste source de vérité). Budget VPS : **1 Go RAM** conteneur, volume données **5 Go** (loop ext4).

```bash
sudo ./install.sh neo4j
```

| Port | Rôle |
|------|------|
| `7687` | Bolt (`127.0.0.1` + gateway k3s) |
| `7474` | Browser HTTP local |

Secrets : `neo4j/.env.neo4j` · données : `/var/lib/wise-eat/neo4j`.  
API : `NEO4J_URI=bolt://host.k3s.internal:7687` avec `NEO4J_ENABLED=false` jusqu’au go-live (voir `africa-meals-project/docs/NEO4J_INTEGRATION.md`).

**Admin web (Neo4j Browser)** — `https://db-graph.wise-eat.com` (basic auth nginx).  
DbGate ne supporte pas Neo4j ; on expose le Browser natif + Bolt TLS sur `:7688`.

```bash
# DNS A (+ AAAA) db-graph.wise-eat.com → VPS
# Cloudflare : proxy OK sur 443 ; port 7688 en DNS only
sudo ./install.sh neo4j
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh neo4j-admin
# Si 502 :
sudo ./install.sh repair-neo4j-admin
```

| URL / port | Rôle |
|------------|------|
| `https://db-graph.wise-eat.com` | Neo4j Browser — auth nginx puis login Neo4j |
| `bolt+s://db-graph.wise-eat.com:7688` | Bolt TLS (nginx stream → :7687 local) |
| `http://127.0.0.1:7474` | Browser local (sans nginx) |

Dans le Browser : Connect URI = `bolt+s://db-graph.wise-eat.com:7688`, user/password = `NEO4J_USER` / `NEO4J_PASSWORD`.  
Identifiants nginx : `NEO4J_ADMIN_BASIC_AUTH_*` dans `neo4j/.env.neo4j`.

**Monitoring Grafana** : dossier `Neo4j/` — **Wise Eat — Neo4j** ([PapaDanielVi/neo4j-exporter](https://github.com/PapaDanielVi/neo4j-exporter), Bolt → `:9217`, `job=neo4j`) + panneaux cAdvisor du conteneur `wise-eat-neo4j`. Les credentials Bolt sont synchronisés depuis `neo4j/.env.neo4j` vers `.env.monitoring` à l’install.

```bash
sudo ./install.sh neo4j          # si pas encore démarré
sudo ./install.sh monitoring     # démarre neo4j-exporter + scrape Prometheus
# ou si Grafana Neo4j « No data » :
sudo ./install.sh repair-neo4j-prometheus
curl -s http://127.0.0.1:9217/metrics | grep '^neo4j_exporter_up '
```

Alertes Prometheus : `monitoring/prometheus/alerts/neo4j.yml` (exporter down, Neo4j down, heap élevé, DB offline).

**Core System (VPS)** : dossier Grafana `Core System/` avec :
- **Wise Eat — System (Node Exporter)** (#1860) — `node_exporter` `:9100`, job `node`
- **Wise Eat — Docker Monitoring** (#4271) — `cAdvisor` `:8088`, job `cadvisor` (+ métriques `node_*` alignées sur instance `wise-eat:9100`)

Si le panel **Containers** affiche **N/A** et les graphiques « per Container » sont vides (node_exporter OK, cAdvisor UP) :

```bash
sudo ./install.sh repair-cadvisor
```

Si les logs cAdvisor mentionnent `overlayfs/layerdb/mounts/.../mount-id: no such file` (Docker 29 + **containerd-snapshotter**) :

```bash
# 1. cAdvisor v0.60+ (inclus dans git pull)
sudo ./install.sh repair-cadvisor

# 2. Si toujours vide — désactive containerd-snapshotter (~1 min coupure Docker)
sudo ./install.sh repair-docker-daemon-cadvisor
```

Cause : Docker 29 stocke les images via containerd-snapshotter (`Storage Driver: overlayfs`). cAdvisor < v0.54 ne lit plus ce layout. `--disable_metrics=disk` seul ne suffit pas sur v0.53.

**MinIO** : dossier Grafana `MinIO/` avec **Wise Eat — MinIO Storage** (équivalent Prometheus du #20826) — scrape `minio-cluster` + `minio-node`.

**EMQX** : dossier Grafana `EMQX/` avec **Wise Eat — EMQX** (base Grafana.com #17446) — scrape `job=emqx` sur `/api/v5/prometheus/stats` (primary + réplicas).

**MongoDB** : dossier Grafana `MongoDB/` avec **Wise Eat — MongoDB** (#12079, Percona legacy) et **Wise Eat — MongoDB Overview** (#18847, métriques ss/sys) — scrape `job=mongodb` via Percona exporter.

**Ollama** : dossier Grafana `Ollama/` — **Wise Eat — Ollama LLM Inference** (#25086, `ollama-exporter`).

**Neo4j** : dossier Grafana `Neo4j/` — **Wise Eat — Neo4j** (`neo4j-exporter` Bolt, `:9217`, `job=neo4j`).

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

Dans `monitoring/.env.monitoring` : `GRAFANA_ROOT_URL=https://console.wise-eat.com/` puis recréer **Grafana seul** (Prometheus est souvent géré hors Compose sur VPS k3s) :

```bash
cd monitoring && docker compose --env-file .env.monitoring up -d --no-deps --force-recreate grafana
```

Ou, si `wise-eat-prometheus` a été créé via `k8s/scripts/recreate-prometheus-host.sh` :

```bash
sudo k8s/scripts/recreate-grafana-host.sh
```

**Alertes e-mail (SMTP Zoho)** — dans `monitoring/.env.monitoring` (`GRAFANA_SMTP_*`, voir `.env.example`), puis l’une des commandes ci-dessus. Tester dans Grafana : Alerting → Contact points.

### Prometheus public (`logs.wise-eat.com`)

Prometheus n’a pas d’auth native : protection via **nginx basic auth** + TLS.

| Mode | Commande |
|------|----------|
| **VPS nginx + TLS** | `sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh prometheus-logs` |

Le mot de passe basic auth est dans `monitoring/.env.monitoring` (`PROMETHEUS_BASIC_AUTH_USER` / `PROMETHEUS_BASIC_AUTH_PASSWORD`), généré par `./install.sh monitoring` si absent.

Dans `monitoring/.env.monitoring` : `PROMETHEUS_EXTERNAL_URL=https://logs.wise-eat.com/` puis :

```bash
# VPS k3s : Prometheus est en docker run (host network), pas via compose
sudo k8s/scripts/recreate-prometheus-host.sh
```

Si Prometheus est géré entièrement par Compose (pas de conflit de nom) :

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

**Volume 10 Go** : loop ext4 `/var/lib/wise-eat/minio-data.img` monté sur `/var/lib/wise-eat/minio` (ou `MINIO_DATA_DEVICE` pour un disque dédié). Pour réduire un volume existant sans perte de données, mettre `MINIO_STORAGE_GB=10` dans `minio/.env.minio` puis relancer `sudo ./install.sh minio` (ou `minio-replication` pour les réplicas) — la réduction est ignorée si l'espace utilisé dépasse la cible.

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
- **Mnesia / Erlang VM** : collecteurs legacy `EMQX_PROMETHEUS__*_COLLECTOR` dans `emqx/docker-compose.yml` (`vm_memory`, `vm_system_info`, `vm_statistics`, `mnesia`). Ne pas utiliser `EMQX_PROMETHEUS__ENABLE` + `EMQX_PROMETHEUS__COLLECTORS__*` (conflit schéma EMQX 5.8).

Si Grafana affiche **No data** :
```bash
sudo ./install.sh repair-emqx-prometheus
```

Si EMQX **crash-loop** (`unknown => "collectors"`, 502 sur `worker.wise-eat.com`) :
```bash
cd /opt/wise-eat && git pull
sudo ./install.sh repair-emqx-boot
```

## MongoDB

Base de données self-hosted **MongoDB 8** — replica set **rs0** (1 primary + 2 réplicas), volume **5 Go**, **512 Mo RAM** par nœud + swap (**1,5 Go** total rs0).

```bash
sudo ./install.sh mongodb
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls
sudo ./install.sh mongodb-tls
sudo ./install.sh mongodb-admin
```

| Port / URL | Service |
|------------|---------|
| `mongodb://127.0.0.1:27017` | Primary local (PM2 sur VPS) |
| `127.0.0.1:27027` / `:27028` | Réplicas locaux |
| `db.wise-eat.com:27018` | MongoDB TLS public (Stunnel → primary) |
| `https://data.wise-eat.com` | DbGate admin MongoDB (basic auth nginx) |

**Sécurité** :
- TLS transport (Stunnel + Let's Encrypt sur `db.wise-eat.com`)
- Auth SCRAM-SHA-256 + keyfile inter-nœuds
- Basic auth nginx sur la console admin

**DbGate** (`data.wise-eat.com`) : panneau web MongoDB (requêtes, export, navigation collections). Connexion préconfigurée vers le primary. Auth nginx uniquement (`SKIP_ALL_AUTH=1` côté DbGate).

```bash
sudo ./install.sh repair-mongodb-admin   # migration mongo-express → DbGate
```

**URI applicative** (ex. API / WS) :

```env
# VPS local (PM2)
MONGODB_URI=mongodb://wise-eat-app:PASSWORD@127.0.0.1:27017/wise_eat_db?authSource=admin&replicaSet=rs0

# Remote (TLS)
MONGODB_URI=mongodb://wise-eat-app:PASSWORD@db.wise-eat.com:27018/wise_eat_db?authSource=admin&tls=true&directConnection=true

# Lectures API sur replicas (défaut secondaryPreferred) — voir africa-meals-project/docs/DATABASE_SCALING.md
# MONGO_READ_PREFERENCE=secondaryPreferred
```

**Backups** :

```bash
sudo ./scripts/install-mongodb-backup.sh   # cron dump quotidien + snapshot hebdo
sudo ./scripts/backup-mongodb.sh          # run manuel
sudo ./scripts/restore-mongodb.sh         # smoke restore staging (écrase la DB)
```

**Renommer la base** (ex. migration depuis `african_meals_db`) :

```bash
# Sur le VPS — copie les données + met à jour .env.mongodb et droits wise-eat-app
sudo MONGO_APP_DATABASE_NEW=wise_eat_db ./install.sh rename-mongodb-database

# Sans copie (base vide / déjà migrée via l’admin)
sudo MONGO_RENAME_COPY_DATA=0 MONGO_APP_DATABASE_NEW=wise_eat_db ./install.sh rename-mongodb-database
```

Secrets dans `mongodb/.env.mongodb` (générés à l’install).

**Sauvegarde locale** : dump quotidien (override `latest/`) + snapshot hebdomadaire (hardlinks rsync) → `/var/backups/wise-eat-mongodb` (cron 03:30).

**Sauvegarde cloud (hebdo)** : archive `.tar.gz` vers GCS, Firebase Storage et AWS S3 — rotation `Backup_DB_1` … `Backup_DB_4` (écrasement mensuel). **Credentials** : `/opt/wise-eat-api/.env.prod` (buckets + AWS + `accounts.json`).

```bash
sudo ./scripts/mongodb-backup.sh install-all      # crons local + cloud
sudo ./scripts/mongodb-backup.sh env-check        # URIs résolues depuis .env.prod
sudo ./scripts/mongodb-backup.sh local            # test dump
sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud
```

Documentation : [docs/MONGODB_BACKUP.md](docs/MONGODB_BACKUP.md) · [docs/MONGODB_BACKUP.html](docs/MONGODB_BACKUP.html)

**Grafana** : dossier **MongoDB** → **Wise Eat — MongoDB** (#12079) et **Wise Eat — MongoDB Overview** (#18847, Percona ss/sys).

Si Grafana affiche **No data** :
```bash
sudo ./install.sh repair-mongodb-prometheus
```

Si l'install **bloque sur rs.initiate()** (majorité 2/3 requise) :
```bash
# Ctrl+C puis :
sudo ./install.sh repair-mongodb-replicaset
```

Si **data.wise-eat.com** affiche 502 / erreur connexion MongoDB dans les logs DbGate :
```bash
sudo ./install.sh repair-mongodb-replicaset   # init rs0 + PRIMARY
sudo ./install.sh repair-mongodb-admin        # ou ce seul script (appelle replicaset)
```

DNS A + AAAA `db.wise-eat.com` → VPS. Port **27018** : **DNS only** sur Cloudflare (comme Redis Stunnel).
DNS A `data.wise-eat.com` → VPS (proxy Cloudflare OK pour HTTPS).
