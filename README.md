# africa-meals-infra

Infra VPS Wise Eat : Redis, Stunnel (Mode A), monitoring Prometheus/Grafana.

**Remote :** `https://github.com/AfrikanMeals/africa-meals-infra.git`

## Structure

```
install.sh              → point d'entrée unique
scripts/
  lib/common.sh         → chemins, helpers
  install-redis.sh
  install-stunnel.sh
  install-monitoring.sh
  fix-redis-permissions.sh
redis/                  → Docker Compose + configs Stunnel
monitoring/             → Prometheus + Grafana
```

## Installation (VPS)

```bash
git clone https://github.com/AfrikanMeals/africa-meals-infra.git /opt/wise-eat
cd /opt/wise-eat
chmod +x install.sh scripts/*.sh scripts/lib/*.sh

sudo ./install.sh redis              # Redis + secrets + ACL
sudo ./install.sh permissions        # si ACL Permission denied
sudo GCP_EGRESS_IP=x.x.x.x ./install.sh stunnel   # Mode A API → VPS
sudo ./install.sh monitoring         # Prometheus + Grafana
sudo ./install.sh all                # redis + permissions + monitoring
```

```bash
./install.sh --help
```

| Composant | Rôle |
|-----------|------|
| `redis` | Docker cache `:6379` + BullMQ `:6380`, génère `.env.redis` + ACL |
| `stunnel` | TLS `:6381` / `:6382` pour Cloud Functions (env `GCP_EGRESS_IP`) |
| `monitoring` | redis_exporter + Prometheus + Grafana |
| `permissions` | `chown 999:999` ACL + data (fix Restarting) |
| `all` | `redis` + `permissions` + `monitoring` |

Variables :

- `WISE_EAT_ROOT` — racine déploiement (défaut : racine du clone, ex. `/opt/wise-eat`)
- `GCP_EGRESS_IP` — IP egress statique GCP (obligatoire pour `stunnel`)

Runbooks détaillés : monorepo AfrikaMeals → `docs/REDIS_VPS_PRODUCTION.md`, `docs/REDIS_MONITORING.md`.

## Mise à jour

```bash
cd /opt/wise-eat
git pull origin main
sudo ./install.sh redis          # recopie compose si WISE_EAT_ROOT ≠ clone
sudo ./install.sh monitoring
```

Fichiers runtime ignorés par Git : `redis/.env.redis`, `redis/data-*`, `*.acl`, `monitoring/.env.monitoring`.

## Git — unrelated histories

Si `git pull` échoue avec *refusing to merge unrelated histories* :

```bash
mkdir -p /root/wise-eat-backup
cp -a redis/.env.redis redis/*.acl /root/wise-eat-backup/ 2>/dev/null || true
git fetch origin && git checkout -B main && git reset --hard origin/main
cp /root/wise-eat-backup/* redis/ 2>/dev/null || true
sudo ./install.sh permissions
```
