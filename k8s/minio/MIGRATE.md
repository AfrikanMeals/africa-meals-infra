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
- Relancer `install.sh minio-replication` au cutover (`mc admin replicate add` peut `rb --force` les buckets réplicas)
- Deux writers sur le même volume (Docker Up + pod Ready)

## Vérifications post-cutover

```bash
curl -sf http://127.0.0.1:9000/minio/health/live
curl -sf http://127.0.0.1:9002/minio/health/live
curl -sf http://127.0.0.1:9004/minio/health/live
curl -sfI https://storage.wise-eat.com/minio/health/live

kubectl -n wise-eat get deploy,pods -l app.kubernetes.io/name=minio
kubectl -n wise-eat exec deploy/africa-meals-api -- \
  wget -qO- http://host.k3s.internal:9000/minio/health/live

# Upload smoke depuis l’API (média) + URL publique storage.wise-eat.com
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
