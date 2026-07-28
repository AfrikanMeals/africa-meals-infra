# Migration Neo4j Docker → K8s

## Objectif

Remplacer le conteneur Docker `wise-eat-neo4j` par un Deployment k3s **hostPath / hostPort** :

| Surface | Port | Usage |
|---------|------|--------|
| HTTP Browser | `:7474` | local + nginx `db-graph.wise-eat.com` |
| Bolt | `:7687` | API `bolt://host.k3s.internal:7687` · nginx TLS `:7688` |

- **Volume** : `/var/lib/wise-eat/neo4j/{data,logs,import,plugins}` (loop 5 Go — inchangé)
- **Auth** : Secret `neo4j-config` ← `.env.neo4j` (`NEO4J_AUTH=user/password`)
- **UID** : `7474` (image officielle)
- **RAM** : request **512Mi** · limit **1Gi** (heap/pagecache via secret)
- **Grafana** : exporter → `host.docker.internal:7687`, metrics `:9217`

## Cutover (prod)

```bash
cd /opt/wise-eat && git pull
chmod +x k8s/scripts/migrate-neo4j-docker-to-k8s.sh \
         k8s/scripts/create-neo4j-secret.sh \
         k8s/scripts/repair-neo4j-exporter-host.sh

# Mémoire requests (besoin ~512Mi libres)
kubectl describe node | grep -A6 'Allocated resources'

# Dry-run
sudo k8s/scripts/migrate-neo4j-docker-to-k8s.sh --dry-run

# Cutover
sudo ./install.sh migrate-neo4j-k8s
```

Si pod `Pending` (Insufficient memory) :

```bash
kubectl -n wise-eat patch deploy/neo4j --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"256Mi"}
]'
```

Si pod `CrashLoopBackOff` :

```bash
kubectl -n wise-eat logs deploy/neo4j --tail=80
```

| Log | Fix |
|-----|-----|
| `Unrecognized setting … PORT.7687.TCP.PORT` | `enableServiceLinks: false` (déjà dans le Deployment) |
| `Folder /logs is not accessible for user: 7474` | `chown -R 7474:7474 /var/lib/wise-eat/neo4j` + initContainer |

```bash
chown -R 7474:7474 /var/lib/wise-eat/neo4j
kubectl apply -k k8s/neo4j
kubectl -n wise-eat rollout status deploy/neo4j --timeout=300s
```

## Vérifications

```bash
curl -sf http://127.0.0.1:7474/ | head -c 80
kubectl -n wise-eat get pods -l app.kubernetes.io/name=neo4j
kubectl -n wise-eat exec deploy/neo4j -- \
  cypher-shell -u neo4j -p "$NEO4J_PASSWORD" 'RETURN 1 AS ok;'

# API pod → Bolt
kubectl -n wise-eat exec deploy/africa-meals-api -- \
  sh -c 'nc -z -w 2 host.k3s.internal 7687 && echo OK'

# Grafana
curl -sf http://127.0.0.1:9217/metrics | grep '^neo4j_exporter_up '

# Public
# https://db-graph.wise-eat.com
# bolt+s://db-graph.wise-eat.com:7688
```

## Apply sans cutover

```bash
sudo ./install.sh neo4j-k8s
sudo ./install.sh repair-neo4j-exporters
```

## Rollback

```bash
kubectl -n wise-eat scale deploy/neo4j --replicas=0
# attendre ports 7474/7687 libres

cd /opt/wise-eat/neo4j
set -a && source .env.neo4j && set +a
docker compose --env-file .env.neo4j up -d

# Exporter Docker DNS (optionnel)
# NEO4J_URI=bolt://wise-eat-neo4j:7687 dans monitoring + compose up neo4j-exporter
```

## Interdits

- `docker compose down -v` ou wipe `/var/lib/wise-eat/neo4j`
- Relancer `install.sh neo4j` (Docker) alors que le pod hostPort est Ready
- Changer `NEO4J_PASSWORD` au cutover sans sync API secret
- Deux writers (Docker Up + pod Ready)

## Fichiers

- Manifests : `k8s/neo4j/`
- Secret : `k8s/scripts/create-neo4j-secret.sh`
- Cutover : `k8s/scripts/migrate-neo4j-docker-to-k8s.sh`
- Exporter : `k8s/scripts/repair-neo4j-exporter-host.sh` · `monitoring/docker-compose.yml`
