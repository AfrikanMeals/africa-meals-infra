# Migration Memcached Docker → K8s

## Objectif

Remplacer les conteneurs Docker `wise-eat-memcached` (+ 2 réplicas standby) par des pods k3s **hostPort** :

| Site | Port hôte | Conteneur Docker (avant) |
|------|-----------|--------------------------|
| Primaire | `:11211` | `wise-eat-memcached` |
| Réplica 1 | `:11213` | `wise-eat-memcached-replica-1` |
| Réplica 2 | `:11214` | `wise-eat-memcached-replica-2` |

- **API / WS** : déjà `MEMCACHED_SERVERS=host.k3s.internal:11211` (+ réplicas) — **pas de changement de secret**
- **Credentials** : **aucun** (pas de SASL Memcached)
- **Données** : cache **RAM uniquement** — cutover = cache froid (attendu, pas de backup objets)
- **Stunnel TLS** `:11212` → `127.0.0.1:11211` inchangé (hostPort)
- **Grafana** : exporters en `network_mode: host` → `127.0.0.1:11211/13/14` (jobs Prometheus `:9150/51/52` inchangés)

## Cutover (prod)

```bash
cd /opt/wise-eat && git pull
chmod +x k8s/scripts/migrate-memcached-docker-to-k8s.sh \
         k8s/scripts/repair-memcached-exporters-host.sh

# Dry-run
sudo k8s/scripts/migrate-memcached-docker-to-k8s.sh --dry-run

# Cutover
sudo ./install.sh migrate-memcached-k8s
```

## Vérifications

```bash
printf 'stats\nquit\n' | nc -w 2 127.0.0.1 11211 | head
printf 'stats\nquit\n' | nc -w 2 127.0.0.1 11213 | head
printf 'stats\nquit\n' | nc -w 2 127.0.0.1 11214 | head

kubectl -n wise-eat get deploy,pods -l app.kubernetes.io/name=memcached
kubectl -n wise-eat exec deploy/africa-meals-api -- \
  sh -c "printf 'version\nquit\n' | nc -w 2 host.k3s.internal 11211"

curl -sf http://127.0.0.1:9150/metrics | grep '^memcached_up '
curl -sf http://127.0.0.1:9151/metrics | grep '^memcached_up '
curl -sf http://127.0.0.1:9152/metrics | grep '^memcached_up '

# Grafana dashboard Memcached — séries UP
```

Si exporters DOWN :

```bash
sudo ./install.sh repair-memcached-exporters
```

## Apply sans cutover

```bash
sudo ./install.sh memcached-k8s
sudo ./install.sh repair-memcached-exporters
```

## Rollback

```bash
kubectl -n wise-eat scale deploy/memcached deploy/memcached-replica-1 deploy/memcached-replica-2 --replicas=0
# attendre ports libres (~15s)

cd /opt/wise-eat/memcached
set -a && source .env.memcached && set +a
docker compose --env-file .env.memcached --profile cluster-b up -d

# Remettre exporters Docker DNS (si besoin) :
# cd /opt/wise-eat/monitoring && docker compose --profile cluster-b up -d memcached-exporter …
```

## Interdits

- Relancer `install.sh memcached` (Docker) alors que les pods hostPort sont Ready
- Deux writers sur le même port (Docker Up + pod Ready)
- Attendre une « restauration » du cache — Memcached n’est pas persistant

## Fichiers

- Manifests : `k8s/memcached/`
- Cutover : `k8s/scripts/migrate-memcached-docker-to-k8s.sh`
- Exporters : `k8s/scripts/repair-memcached-exporters-host.sh` · `monitoring/docker-compose.yml`
