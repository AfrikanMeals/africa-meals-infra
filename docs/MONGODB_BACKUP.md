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

Utiliser un bucket **dédié backups** (distinct du bucket médias publics) si possible.
