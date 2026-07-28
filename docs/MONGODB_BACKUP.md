# Sauvegarde MongoDB — Wise Eat

Guide opérationnel pour les scripts dans `africa-meals-infra` (VPS `/opt/wise-eat`).

## Vue d’ensemble

| Niveau | Fréquence | Destination | Script |
|--------|-----------|-------------|--------|
| **Local** | Quotidien 03:30 | `/var/backups/wise-eat-mongodb` | `backup-mongodb.sh` |
| **Cloud** | Dimanche 04:00 | GCS + Firebase Storage + AWS S3 | `upload-mongodb-cloud-backup.sh` |

**CLI unifiée** :

```bash
sudo ./scripts/mongodb-backup.sh <commande>
```

## Credentials cloud

Les uploads cloud lisent **`/opt/wise-eat-api/.env.prod`** (variable `MONGO_CLOUD_API_ENV`).

| Variable `.env.prod` | Usage backup |
|----------------------|--------------|
| `GCS_BUCKET` ou `GOOGLE_CLOUD_STORAGE_BUCKET` | `gs://{bucket}/mongodb/` |
| `AM_FIREBASE_STORAGE_BUCKET` | `gs://{bucket}/mongodb/` |
| `AWS_S3_BUCKET`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `s3://{bucket}/mongodb/` |
| `GOOGLE_APPLICATION_CREDENTIALS` ou `AM_FIREBASE_SERVICE_ACCOUNT_PATH` | Compte de service Google |
| `{API_DIR}/accounts.json` | Repli si chemin SA absent |

La planification et les flags restent dans **`mongodb/.env.mongodb`**.

## Rotation cloud (4 emplacements / mois)

Chaque dimanche, une archive **complète** `.tar.gz` **écrase** le slot de la semaine :

| Jours du mois | Objet |
|---------------|-------|
| 1–7 | `Backup_DB_1.tar.gz` |
| 8–14 | `Backup_DB_2.tar.gz` |
| 15–21 | `Backup_DB_3.tar.gz` |
| 22–fin | `Backup_DB_4.tar.gz` |

→ **4 fichiers max** par destination cloud, renouvelés chaque mois.

## Installation

```bash
cd /opt/wise-eat
sudo git pull

# 1. MongoDB + backup local (si pas déjà fait)
sudo ./install.sh mongodb

# 2. Activer cloud dans mongodb/.env.mongodb
#    MONGO_CLOUD_BACKUP_ENABLED=1
#    MONGO_CLOUD_API_ENV=/opt/wise-eat-api/.env.prod

# 3. Crons
sudo ./scripts/mongodb-backup.sh install-all
```

Prérequis VPS : `gcloud` ou `gsutil`, `aws` CLI.

```bash
sudo ./install.sh mongodb-cloud-tools
sudo ./scripts/mongodb-backup.sh preflight
sudo ./scripts/mongodb-backup.sh env-check
```

**Comptes de service** (`.env.prod`) :
- **GCS** (`GCS_BUCKET`) → `accounts.json` ou `GOOGLE_APPLICATION_CREDENTIALS`
- **Firebase** (`AM_FIREBASE_STORAGE_BUCKET` wise-eat-com) → `recaptcha-accounts.json` (compte de service reCAPTCHA dédié)
- **AWS S3** → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` avec `s3:PutObject` sur `mongodb/*`

### Bucket GCS privé (PAP)

Les backups Mongo utilisent la SA authentifiée — **compatibles** avec Public Access Prevention et sans `allUsers`.

Avant de retirer la lecture anonyme sur le bucket médias + backups :

1. Activer le **proxy médias** API (`/medias/public/…`) si le même bucket sert le catalogue.
2. Appliquer le runbook : `africa-meals-api/docs/FIREBASE_STORAGE.md` § Production private bucket
3. Script : `GCS_BUCKET=… ./scripts/harden-gcs-bucket.sh` puis `APPLY=1` (versioning recommandé pour `mongodb/`)

### Bucket S3 privé (Block Public Access)

Si les backups Mongo et les médias partagent `AWS_S3_BUCKET` :

1. Proxy médias ON (forcé si S3 dans le pool admin) — voir `africa-meals-api/docs/S3_STORAGE.md`
2. Ne pas définir `AWS_S3_PUBLIC_BASE_URL` (pas de CloudFront)
3. Script : `AWS_S3_BUCKET=… ./scripts/harden-s3-bucket.sh` puis `APPLY=1`
4. Les uploads backup restent authentifiés IAM sur `mongodb/*` — compatibles bucket privé

## Commandes

```bash
# Dump local immédiat
sudo ./scripts/mongodb-backup.sh local

# Vérifier config résolue depuis .env.prod
./scripts/mongodb-backup.sh env-check

# Simuler upload cloud
sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud-dry-run

# Upload cloud réel (forcer hors dimanche)
sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud

# État crons + taille backups + logs
./scripts/mongodb-backup.sh status

# Tests logique rotation
./scripts/mongodb-backup.sh self-test

# Aide restauration
./scripts/mongodb-backup.sh restore-help
```

## Logs

| Fichier | Contenu |
|---------|---------|
| `/var/log/wise-eat-mongodb-backup.log` | Dump local quotidien |
| `/var/log/wise-eat-mongodb-cloud-backup.log` | Upload cloud hebdo |
| `/var/backups/wise-eat-mongodb/latest/.backup-ok.json` | Marqueur dernier dump local |
| `/var/backups/wise-eat-mongodb/last-cloud-backup.meta.json` | Marqueur dernier upload cloud |

## Dépannage (backup bloqué / meta ancien)

Si `last-cloud-backup.meta.json` (ou l’objet S3/GCS) date de plusieurs semaines :

1. **PATH cron sans snap** — `gcloud` est souvent dans `/snap/bin`, absent du PATH minimal de `/etc/cron.d`.  
   → `sudo ./scripts/mongodb-backup.sh install-all` (réécrit les crons avec `/snap/bin`).
2. **Auth gcloud** — le CLI n’utilise **pas** `GOOGLE_APPLICATION_CREDENTIALS` ; les scripts forcent `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`.  
   → `sudo ./scripts/mongodb-backup.sh preflight`
3. **Dump local** — ne plus écrire dans `/data/db` (volume WiredTiger 5 Go). Dump vers `/tmp` dans le conteneur.  
   → `sudo ./scripts/mongodb-backup.sh local`
4. Relancer cloud :  
   `sudo MONGO_CLOUD_BACKUP_FORCE=1 ./scripts/mongodb-backup.sh cloud`

## Restauration (résumé)

1. Télécharger `Backup_DB_N.tar.gz` depuis S3 / GCS / Firebase.
2. Extraire : `tar -xzf Backup_DB_N.tar.gz -C /tmp/mongo-restore/`
3. Copier dans le conteneur et `mongorestore --gzip --drop`.

Détail : `./scripts/mongodb-backup.sh restore-help` ou [MONGODB_BACKUP.html](./MONGODB_BACKUP.html).

## Fichiers infra

| Fichier | Rôle |
|---------|------|
| `scripts/mongodb-backup.sh` | CLI |
| `scripts/backup-mongodb.sh` | Dump local |
| `scripts/upload-mongodb-cloud-backup.sh` | Upload cloud |
| `scripts/lib/api-env.sh` | Lecture `.env.prod` |
| `scripts/lib/mongodb-cloud-backup-env.sh` | Mapping credentials |
| `scripts/lib/mongodb-cloud-backup.sh` | Archive + slot semaine |
| `/etc/cron.d/wise-eat-mongodb-backup` | Cron local |
| `/etc/cron.d/wise-eat-mongodb-cloud-backup` | Cron cloud |

## IAM minimal (cloud)

- **GCS / Firebase** : rôle `Storage Object Admin` (ou `Creator` + `Viewer`) sur le préfixe `mongodb/`.
- **AWS S3** : `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` sur `arn:aws:s3:::BUCKET/mongodb/*`.

Utiliser un bucket **dédié backups** (distinct du bucket médias) si possible.
