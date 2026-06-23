# africa-meals-infra

Infra VPS Wise Eat : Redis, Stunnel (Mode A-lite), monitoring Prometheus/Grafana.

**Remote :** `https://github.com/AfrikanMeals/africa-meals-infra.git`

## Structure

```
install.sh              → point d'entrée unique
scripts/
  lib/common.sh
  install-redis.sh
  install-stunnel.sh      → A-lite par défaut
  install-monitoring.sh
  fix-redis-permissions.sh
redis/
monitoring/
```

## Installation (VPS)

```bash
git clone https://github.com/AfrikanMeals/africa-meals-infra.git /opt/wise-eat
cd /opt/wise-eat
chmod +x install.sh scripts/*.sh

sudo ./install.sh redis
sudo ./install.sh stunnel          # A-lite prod (sans Cloud NAT)
sudo ./install.sh monitoring
sudo ./install.sh all              # redis + permissions + monitoring
```

Optionnel — A-strict avec Cloud NAT : `sudo GCP_EGRESS_IP=x.x.x.x ./install.sh stunnel`

| Composant | Rôle |
|-----------|------|
| `redis` | Docker cache `:6379` + BullMQ `:6380` |
| `stunnel` | TLS `:6381` / `:6382` pour Cloud Functions (**A-lite** par défaut) |
| `monitoring` | Prometheus + Grafana |
| `permissions` | Fix ACL `chown 999:999` |
| `all` | redis + permissions + monitoring |

Runbooks : `docs/REDIS_VPS_PRODUCTION.md`, `docs/REDIS_MONITORING.md` (monorepo AfrikaMeals).

## Mise à jour

```bash
cd /opt/wise-eat && git pull origin main
sudo ./install.sh stunnel    # réapplique UFW + Stunnel A-lite
```

## Git — unrelated histories

```bash
mkdir -p /root/wise-eat-backup
cp -a redis/.env.redis redis/*.acl /root/wise-eat-backup/ 2>/dev/null || true
git fetch origin && git checkout -B main && git reset --hard origin/main
cp /root/wise-eat-backup/* redis/ 2>/dev/null || true
sudo ./install.sh permissions
```
