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

# 3. TLS (Certbot + Stunnel Redis + HTTPS site)
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh certbot
sudo ./install.sh stunnel

# 4. Monitoring
sudo ./install.sh monitoring
```

**Une commande** après nginx :

```bash
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls
```

> **nginx et apache** ne tournent pas ensemble sur le port 80 — l’install de l’un arrête l’autre.

## Variables

| Variable | Défaut | Rôle |
|----------|--------|------|
| `WISE_EAT_DOMAIN` | `wise-eat.cloud` | vhost + certificat |
| `WS_BACKEND_PORT` | `8000` | PM2 WS prod |
| `STUNNEL_TLS_EMAIL` | — | Let's Encrypt |
| `WEB_SERVER` | `nginx` | pour `./install.sh web` |

## Composants `install.sh`

| Composant | Description |
|-----------|-------------|
| `nginx` | Installe nginx, proxy → WS, webroot Certbot |
| `apache` | Installe apache2, proxy → WS, webroot Certbot |
| `web` | `WEB_SERVER=nginx\|apache` |
| `certbot` | LE + HTTPS site + certs Stunnel |
| `stunnel` | Redis TLS :6381/:6382 |
| `tls` | certbot + stunnel |
| `redis` / `memcached` / `minio` / `monitoring` / `permissions` | voir runbooks |

## Memcached

Cache applicatif (alternative à Redis pour `CACHE_STORE=memcached`).

```bash
sudo ./install.sh memcached
```

| Port | Service |
|------|---------|
| `11211` | Memcached (localhost) |

Variables API : `MEMCACHED_SERVERS=127.0.0.1:11211`

## MinIO

Stockage S3-compatible pour médias (`STORAGE_ENGINE=minio`).

```bash
sudo ./install.sh minio
```

| Port | Service |
|------|---------|
| `9000` | API S3 |
| `9001` | Console web |

Secrets générés dans `minio/.env.minio`. Le script crée le bucket `wise-eat` et affiche les variables `MINIO_*` pour l’API.
