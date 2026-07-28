# Migration Redis Docker → K8s

## Objectif

Remplacer les 6 conteneurs Redis Docker par des pods k3s **hostPath + hostPort** (mêmes données AOF, mêmes ports, mêmes ACL).

| Rôle | Port hôte | Volume hostPath | ACL user |
|------|-----------|-----------------|----------|
| Cache primary | `:6379` | `/opt/wise-eat/redis/data-cache` | `wise-eat-cache` |
| BullMQ primary | `:6380` | `…/data-bullmq` | `wise-eat-bull` |
| Cache replica-1/2 | `:6371` / `:6372` | `…/data-cache-replica-*` | `wise-eat-cache` |
| Bull replica-1/2 | `:6390` / `:6391` | `…/data-bullmq-replica-*` | `wise-eat-bull` |

- **API / WS** : déjà `host.k3s.internal` + ports plaintext — **mots de passe** doivent rester alignés (`REDIS_PASSWORD` = `CACHE_REDIS_PASSWORD`, `BULLMQ_REDIS_PASSWORD` = `BULL_REDIS_PASSWORD`)
- **replicaof** : Services `redis-cache` / `redis-bullmq` (`*.svc.cluster.local`) — plus DNS Docker
- **TLS public** (HAProxy/Stunnel `cache.wise-eat.com:6381–6386`) → `127.0.0.1` inchangé
- **Grafana** : exporters `network_mode: host` → `127.0.0.1` (jobs `:9121–9126` inchangés)

## Cutover

```bash
cd /opt/wise-eat && git pull
chmod +x k8s/scripts/create-redis-secret.sh \
         k8s/scripts/migrate-redis-docker-to-k8s.sh \
         k8s/scripts/repair-redis-exporters-host.sh

# Vérifier alignement mots de passe API ↔ .env.redis (sans afficher les secrets)
# CACHE_REDIS_PASSWORD dans redis/.env.redis == REDIS_PASSWORD dans .env.prod

sudo k8s/scripts/migrate-redis-docker-to-k8s.sh --dry-run
sudo ./install.sh migrate-redis-k8s
```

Fenêtre : ~1–2 min (stop → Ready). Pause workers BullMQ recommandée.

## Vérifications

```bash
redis-cli -h 127.0.0.1 -p 6379 --user wise-eat-cache -a "$CACHE_REDIS_PASSWORD" ping
redis-cli -h 127.0.0.1 -p 6380 --user wise-eat-bull -a "$BULL_REDIS_PASSWORD" ping
redis-cli -h 127.0.0.1 -p 6371 --user wise-eat-cache -a "$CACHE_REDIS_PASSWORD" INFO replication | head

kubectl -n wise-eat get pods -l app.kubernetes.io/name=redis
curl -sf http://127.0.0.1:9121/metrics | grep '^redis_up '
# … 9122–9126

# TLS public inchangé
# openssl s_client -connect cache.wise-eat.com:6381 </dev/null
```

## Credentials

| Infra `.env.redis` | API / WS secret |
|--------------------|-----------------|
| `CACHE_REDIS_PASSWORD` | `REDIS_PASSWORD` (+ user `wise-eat-cache` / `REDIS_USERNAME`) |
| `BULL_REDIS_PASSWORD` | `BULLMQ_REDIS_PASSWORD` (+ `BULLMQ_REDIS_USERNAME`) |

Après changement de mdp dans `.env.redis` :

```bash
sudo k8s/scripts/create-redis-secret.sh
kubectl -n wise-eat rollout restart deploy -l app.kubernetes.io/name=redis
# Mettre à jour .env.prod + create-api-secret / create-ws-secret + rollout API/WS
sudo ./install.sh repair-redis-exporters
```

## Rollback

```bash
kubectl -n wise-eat scale deploy -l app.kubernetes.io/name=redis --replicas=0
# attendre ports libres

cd /opt/wise-eat/redis
set -a && source .env.redis && set +a
# Régénérer confs replica Docker (DNS wise-eat-redis-*)
sudo ../scripts/install-redis.sh   # ou compose up après rewrite confs Docker
```

Préférer : scale=0 puis `docker compose --env-file .env.redis --profile cluster-b up -d` **si** les `*.generated.conf` Docker existent encore (replicaof `wise-eat-redis-cache`).

## Interdits

- `docker compose down -v` / `rm -rf data-*`
- Deux writers sur le même hostPath
- Changer `maxmemory-policy` BullMQ (`noeviction`)
- Relancer `install.sh redis` (Docker) pendant pods Ready

## Fichiers

- Manifests : `k8s/redis/`
- Secret : `k8s/scripts/create-redis-secret.sh`
- Cutover : `k8s/scripts/migrate-redis-docker-to-k8s.sh`
- Exporters : `k8s/scripts/repair-redis-exporters-host.sh`
