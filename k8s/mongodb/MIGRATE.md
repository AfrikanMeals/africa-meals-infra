# Migration MongoDB Docker → K8s

## Objectif

Remplacer `wise-eat-mongo-{1,2,3}` par des Deployments k3s **sans perte** et **sans rs.reconfig** :

| Nœud | Deploy | Host port | hostPath | Hostname RS |
|------|--------|-----------|----------|-------------|
| Primary | `mongo-1` | `:27017` | `/var/lib/wise-eat/mongodb/data-mongo-1` | `wise-eat-mongo-1` |
| Replica | `mongo-2` | `:27027` | `…/data-mongo-2` | `wise-eat-mongo-2` |
| Replica | `mongo-3` | `:27028` | `…/data-mongo-3` | `wise-eat-mongo-3` |

- Services **headless** `wise-eat-mongo-{1,2,3}` → DNS membres rs0 inchangés
- Secret `mongodb-config` : creds `.env.mongodb` + `keyfile`
- API : `host.k3s.internal:27017` + `directConnection` — **inchangé**
- HAProxy `:27018` → `127.0.0.1:27017` — inchangé
- DbGate : reste Docker → `host.docker.internal:27017`
- Exporter Grafana : `:9216` → même host

## Cutover (prod)

```bash
cd /opt/wise-eat && git pull
chmod +x k8s/scripts/migrate-mongodb-docker-to-k8s.sh \
         k8s/scripts/create-mongodb-secret.sh \
         k8s/scripts/repair-mongodb-exporter-host.sh

# Mémoire : ~3×256Mi requests (+ init) — HPA API/WS min 1 recommandé
kubectl describe node | grep -A6 'Allocated resources'

# Dry-run
sudo k8s/scripts/migrate-mongodb-docker-to-k8s.sh --dry-run

# Cutover (mongodump + stop + apply + rs.status + DbGate + exporter)
sudo ./install.sh migrate-mongodb-k8s
```

Fenêtre : API indisponible Mongo le temps stop Docker → pods Ready (quelques minutes).

## Vérifications

```bash
kubectl -n wise-eat get pods -l app.kubernetes.io/name=mongodb -o wide

set -a && source /opt/wise-eat/mongodb/.env.mongodb && set +a
kubectl -n wise-eat exec deploy/mongo-1 -- \
  mongosh -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval 'rs.status().members.map(m=>m.name+"="+m.stateStr)'

# Stats métier
kubectl -n wise-eat exec deploy/mongo-1 -- \
  mongosh -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval 'db.getSiblingDB("wise_eat_db").stats()'

# API + TLS + Grafana
kubectl -n wise-eat exec deploy/africa-meals-api -- nc -z -w 2 host.k3s.internal 27017 && echo OK
curl -sf http://127.0.0.1:9216/metrics | grep -E '^mongodb_up |^mongodb_mongod_up '
# openssl s_client -connect db.wise-eat.com:27018 </dev/null
# https://data.wise-eat.com (DbGate)
```

## Apply sans cutover

```bash
sudo ./install.sh mongodb-k8s
sudo ./install.sh repair-mongodb-exporters
```

## Rollback

```bash
kubectl -n wise-eat scale deploy/mongo-1 deploy/mongo-2 deploy/mongo-3 --replicas=0
# attendre ports 27017/27027/27028 libres

cd /opt/wise-eat/mongodb
set -a && source .env.mongodb && set +a
# Pré-cutover Docker DNS pour DbGate si besoin :
# MONGO_DBGATE_HOST=wise-eat-mongo-1
docker compose --env-file .env.mongodb up -d

sudo ./scripts/repair-mongodb-prometheus.sh   # ou exporter Docker DNS
```

Restaurer dump (corruption seulement) :

```bash
# Voir docs/MONGODB_BACKUP.md + restore-mongodb.sh
```

## Rollout figé / pods Pending (VPS RAM)

Symptôme : `Waiting for deployment "mongo-1" … 0 out of 1` + icônes warning Headlamp.

```bash
kubectl -n wise-eat get pods -l app.kubernetes.io/name=mongodb -o wide
kubectl -n wise-eat describe pods -l app.kubernetes.io/name=mongodb | grep -E 'Forbidden|Insufficient|Warning|Failed' | tail -30
kubectl describe node | grep -A8 'Allocated resources'
```

**Cause fréquente 1 — LimitRange** : initContainer `cpu: 10m` < min `50m` → pod Forbidden (0 replicas).  
Fix manifests (cpu init ≥ 50m) puis :

```bash
cd /opt/wise-eat && git pull
kubectl apply -k k8s/mongodb
```

**Cause fréquente 2 — Insufficient memory** (~768Mi requests pour 3 nœuds) :

```bash
# Libère ~1 Go de requests (réplicas Redis) — safe court terme
kubectl -n wise-eat scale deploy/redis-cache-replica-1 deploy/redis-cache-replica-2 \
  deploy/redis-bullmq-replica-1 deploy/redis-bullmq-replica-2 --replicas=0
kubectl -n wise-eat scale deploy/africa-meals-api deploy/africa-meals-ws --replicas=1

# Attendre Ready
kubectl -n wise-eat get pods -l app.kubernetes.io/name=mongodb -w

# Puis reprendre la fin du migrate (ou relancer avec SKIP_DUMP=1 SKIP_BACKUP_TAR=1)
SKIP_DUMP=1 SKIP_BACKUP_TAR=1 sudo ./install.sh migrate-mongodb-k8s

# Remettre réplicas Redis
kubectl -n wise-eat scale deploy/redis-cache-replica-1 deploy/redis-cache-replica-2 \
  deploy/redis-bullmq-replica-1 deploy/redis-bullmq-replica-2 --replicas=1
```

### Mid-cutover : `Port :27017 encore occupé`

Normal si les pods k8s tiennent déjà le hostPort. Le script skip automatique si `deploy/mongo-*` + pods existent ; sinon :

```bash
SKIP_DUMP=1 SKIP_BACKUP_TAR=1 SKIP_PORT_WAIT=1 sudo ./install.sh migrate-mongodb-k8s
```

### CrashLoopBackOff (keyfile)

```bash
kubectl -n wise-eat logs deploy/mongo-1 --tail=40
# typique : "permissions on /etc/mongodb/keyfile are too open" / error opening keyFile
```

Cause : Secret monté en root — mongod (UID 999) exige owner 999 + mode `400`.  
Fix : initContainer copie Secret → emptyDir `chown 999` / `chmod 400`, puis :

```bash
cd /opt/wise-eat && git pull && kubectl apply -k k8s/mongodb
kubectl -n wise-eat rollout status deploy/mongo-1 deploy/mongo-2 deploy/mongo-3 --timeout=180s
```

Si Mongo Docker déjà stop et pods toujours impossibles → **rollback Docker** (ports libres d’abord) :

```bash
kubectl -n wise-eat scale deploy/mongo-1 deploy/mongo-2 deploy/mongo-3 --replicas=0
# attendre : ss -tlnp | grep -E '27017|27027|27028' vide
cd /opt/wise-eat/mongodb && docker compose --env-file .env.mongodb up -d
```

## Interdits

- `docker compose down -v` / wipe `data-mongo-*`
- Relancer `install.sh mongodb` (Docker) alors que les pods hostPort sont Ready
- `rs.reconfig` vers d’autres hostnames sans plan
- Cutover sans mongodump (sauf `SKIP_DUMP=1` urgence documentée)
- Deux writers (Docker Up + pod Ready sur les mêmes ports)

## Fichiers

- Manifests : `k8s/mongodb/`
- Secret : `k8s/scripts/create-mongodb-secret.sh`
- Cutover : `k8s/scripts/migrate-mongodb-docker-to-k8s.sh`
- Exporter : `k8s/scripts/repair-mongodb-exporter-host.sh`
