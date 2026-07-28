# Migration MinIO Docker → K8s (zéro perte de données)

## Objectif

Remplacer les conteneurs Docker `wise-eat-minio` (+ 2 réplicas) par des pods k3s qui **réutilisent les mêmes hostPath** :

| Site | Ports hôte | Volume |
|------|------------|--------|
| Primaire | `:9000` / `:9001` | `/var/lib/wise-eat/minio` |
| Réplica 1 | `:9002` / `:9012` | `/var/lib/wise-eat/minio-replica-1` |
| Réplica 2 | `:9004` / `:9014` | `/var/lib/wise-eat/minio-replica-2` |

- **Interne (pods API)** : `http://host.k3s.internal:9000`
- **Public** : `https://storage.wise-eat.com` (nginx → `127.0.0.1:9000`, inchangé)
- **Creds** : mêmes valeurs que `minio/.env.minio`
- **Ressources primary** : request 256Mi/100m · limit **512Mi / 2 CPU** (`replicas: 1` — pas d’HPA MinIO)
- **Charge app** : HPA `africa-meals-api` (5–10), pas de scale horizontal MinIO hostPath

## Prérequis

- k3s opérationnel (`wise-eat` namespace)
- Volumes montés et **non vides**
- nginx `storage.wise-eat.com` / `cdn.wise-eat.com` déjà configurés
- Fenêtre courte (downtime S3 ~1–2 min pendant stop Docker → Ready pods)

## Cutover (prod)

```bash
cd /opt/wise-eat   # ou clone africa-meals-infra
git pull
chmod +x k8s/scripts/*.sh

# Dry-run (aucune mutation)
sudo k8s/scripts/migrate-minio-docker-to-k8s.sh --dry-run

# Cutover complet (backup mc mirror obligatoire)
sudo ./install.sh migrate-minio-k8s
# équivalent :
# sudo k8s/scripts/migrate-minio-docker-to-k8s.sh
```

Le script :

1. Vérifie les 3 volumes
2. Lance `backup-minio.sh` (abort si échec)
3. `ufw-allow-k3s-pods.sh` (CIDR pods → ports MinIO)
4. `docker compose … stop` (**pas** `down -v`)
5. Refuse l’apply si un conteneur MinIO Docker est encore Up
6. `create-minio-secret.sh` + `kubectl apply -k k8s/minio`
7. Health `:9000` / `:9002` / `:9004`
8. Bascule secret API → `MINIO_ENDPOINT=http://host.k3s.internal:9000`
9. `docker compose … down` **sans** `-v`

## Interdits

- `docker compose down -v` / suppression de `/var/lib/wise-eat/minio*`
- Relancer `install.sh minio-replication` au cutover (`mc admin replicate add` peut `rb --force` les buckets réplicas ; script Docker-only)
- Deux writers sur le même volume (Docker Up + pod Ready)

## Post-cutover obligatoire — site-replication

Après le cutover, la SR pointe encore vers les DNS Docker morts (`wise-eat-minio:9000`, …).
Symptômes : `Access Denied` / `PrefixAccessDenied` / PutObject KO ; Grafana Internode vide.

```bash
# Reconfigure SR via Services k8s (in-cluster DNS)
# Prérequis : réplicas sans aucun bucket (le script les vide ; primary garde les données)
sudo ./install.sh repair-minio-site-replication-k8s
```

Si `only one cluster may have data` : lister/vider les buckets restants sur `:9002` / `:9004` puis relancer.

Endpoints attendus après repair :

| Site | Endpoint |
|------|----------|
| primary | `http://minio.wise-eat.svc.cluster.local:9000` |
| replica1 | `http://minio-replica-1.wise-eat.svc.cluster.local:9000` |
| replica2 | `http://minio-replica-2.wise-eat.svc.cluster.local:9000` |

Si PutObject échoue encore avec `PrefixAccessDenied` sur `.minio.sys` :

```bash
chown -R 1000:1000 /var/lib/wise-eat/minio*
rm -rf /var/lib/wise-eat/minio/.minio.sys/buckets/.usage-cache.bin
kubectl -n wise-eat rollout restart deploy/minio deploy/minio-replica-1 deploy/minio-replica-2
```

Resync manuel (syntaxe mc : source + cible) :

```bash
mc admin replicate resync start primary replica1
mc admin replicate resync start primary replica2
```

## Vérifications post-cutover

```bash
# Bundle ops : API + MinIO Admin (cdn) + Grafana/Prometheus
sudo ./install.sh verify-minio-ops

curl -sf http://127.0.0.1:9000/minio/health/live
curl -sf http://127.0.0.1:9001/   # console Admin locale (hostPort)
curl -sf http://127.0.0.1:9002/minio/health/live
curl -sf http://127.0.0.1:9004/minio/health/live
curl -sfI https://storage.wise-eat.com/minio/health/live
# MinIO Admin : https://cdn.wise-eat.com (basic auth nginx puis login MINIO_ROOT_*)

kubectl -n wise-eat get deploy,pods -l app.kubernetes.io/name=minio
kubectl -n wise-eat exec deploy/africa-meals-api -- \
  wget -qO- http://host.k3s.internal:9000/minio/health/live

# Grafana : dashboard MinIO (instance=wise-eat-minio:9000) — si vide :
#   sudo ./install.sh repair-minio-prometheus

# Upload smoke depuis l’API (média) + URL publique storage.wise-eat.com

# Site-replication (après cutover) — endpoints Services k8s, pas Docker
sudo ./install.sh repair-minio-site-replication-k8s
# mc admin replicate info → *.svc.cluster.local (plus wise-eat-minio)
```

## Reprise après échec mid-cutover (Docker stop, pods pas Ready)

MinIO est down tant que les pods ne sont pas Ready. Diagnostiquer :

```bash
kubectl -n wise-eat get pods -l app.kubernetes.io/name=minio
kubectl -n wise-eat describe deploy/minio | tail -40
# Cause fréquente : LimitRange memory.min=256Mi — request 128Mi → Forbidden
```

Corriger (git pull) puis **reprendre** sans re-backup si MinIO est down :

```bash
cd /opt/wise-eat && git pull
sudo ./install.sh migrate-minio-k8s
# le script skip le backup si :9000 down et /var/backups/wise-eat-minio/latest existe
```

Ou apply seul puis attendre Ready :

```bash
sudo ./install.sh minio-k8s
kubectl -n wise-eat rollout status deploy/minio --timeout=300s
sudo ./install.sh verify-minio-ops
```

## Rollback

1. Scale pods à 0 (libère hostPort) :

```bash
kubectl -n wise-eat scale deploy/minio deploy/minio-replica-1 deploy/minio-replica-2 --replicas=0
# attendre ~30s que les ports 9000/9002/9004 soient libres
```

2. Relancer Docker sur les **mêmes** volumes :

```bash
cd /opt/wise-eat/minio   # ou ${INFRA}/minio
set -a && source .env.minio && set +a
docker compose --env-file .env.minio \
  -f docker-compose.yml -f docker-compose.replicas.yml up -d
```

3. Secret API (optionnel — Docker n’écoute que `127.0.0.1`) :

```bash
# Remettre MINIO_ENDPOINT=https://storage.wise-eat.com dans .env.prod si besoin
# puis (temporairement) forcer via edit secret, ou restaurer l’ancien create-api-secret
sudo k8s/scripts/create-api-secret.sh /opt/wise-eat-api/.env.prod
kubectl -n wise-eat rollout restart deploy/africa-meals-api
```

> Note : après ce livrable, `create-api-secret.sh` force `http://host.k3s.internal:9000`.  
> En rollback Docker-only, soit réécrire manuellement le secret vers `https://storage.wise-eat.com`, soit garder nginx public comme endpoint API.

4. Health Docker + HTTPS public + smoke upload.

## Apply sans cutover (pods déjà seuls)

```bash
sudo ./install.sh minio-k8s
```

## Fichiers

- Manifests : `k8s/minio/`
- Secret : `k8s/scripts/create-minio-secret.sh`
- Cutover : `k8s/scripts/migrate-minio-docker-to-k8s.sh`
