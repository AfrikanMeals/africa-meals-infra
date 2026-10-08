# VPS scaling — Hostinger + k3s (`wise-eat`)

Stratégie scale-up / scale-down pour le VPS **wise-eat.cloud** (profil actuel : Hostinger **KVM 2** = 2 vCPU / 8 Go).

## Diagnostic rapide

| Symptôme | Cause typique | Action |
|----------|---------------|--------|
| Plateau CPU Hostinger ~50 % pendant des heures | Throttle auto après usage soutenu | Right-size (`apply-vps-kvm2`) puis surveiller 24 h |
| Load average > 3–4 sur 2 cœurs | Trop de pods HA + HPA haut | Profil kvm2 ; si persiste → upgrade VPS |
| RAM > 85 % + swap + Pending | Requests > capacité | Scale HA → 0 ; plafonner HPA |
| Processus Node / k3s / Neo4j haut CPU | Workloads légitimes, pas malware | Logs pods + HPA ; Neo4j heap réduit |

**Ce n’est pas du malware** : stack HA ×3 (Redis, Memcached, EMQX, MinIO) + Mongo ×3 + Neo4j + API/WS sur **un seul** nœud 2 vCPU.

## Profils GitOps

| Overlay | Cible | Commande |
|---------|-------|----------|
| [`overlays/vps-kvm2`](./overlays/vps-kvm2/) | KVM 2 (2 vCPU / 8 Go) | `sudo ./install.sh apply-vps-kvm2` |
| [`overlays/ha`](./overlays/ha/) | ≥16 Go / multi-nœuds | `sudo ./install.sh apply-ha` |

### Contenu `vps-kvm2`

- HPA API **min 1 / max 2** · WS **min 1 / max 2**
- Deployments HA → `replicas: 0` (Redis ×4, Memcached ×2, EMQX-2/3, MinIO ×2)
- Mongo ×3 **conservé** (failover pod local ; pas de rs.reconfig)
- EMQX seeds → `[emqx@wise-eat-emqx-1]`
- Neo4j heap max **256m**, pagecache **64m**, limit pod **768Mi**
- ConfigMaps API/WS : plus de `REDIS_REPLICA_*` / `MEMCACHED_REPLICA_*`
- MinIO site-replication désactivée avant scale-down

Budget requests cible au calme : **~0,8–1,0 CPU / ~3,5–4,5 Gi**.

## Scale-down (automatique)

| Couche | Comportement |
|--------|----------------|
| API / WS | HPA scale-down après **5 min** de calme (−1 pod / 2 min) |
| Infra stateful | **Pas** d’HPA — profil kvm2 = primaries only |

Urgence manuelle (si overlay pas encore appliqué) :

```bash
kubectl -n wise-eat scale deploy/redis-cache-replica-1 deploy/redis-cache-replica-2 \
  deploy/redis-bullmq-replica-1 deploy/redis-bullmq-replica-2 \
  deploy/memcached-replica-1 deploy/memcached-replica-2 \
  deploy/emqx-2 deploy/emqx-3 \
  deploy/minio-replica-1 deploy/minio-replica-2 --replicas=0
```

## Scale-up horizontal (apps seulement)

| Service | Métriques HPA | Max kvm2 | Max HA overlay |
|---------|---------------|----------|----------------|
| API | CPU 60 % / mem 75 % | **2** | 5 |
| WS | CPU 70 % / mem 80 % | **2** | 3 |

Si HPA est déjà au **max** et latence / 5xx persistent → **ne pas** remonter max à 5 sur KVM 2 ; passer au scale vertical.

## Scale-up vertical (Hostinger)

| Signal (soutenu) | Action |
|------------------|--------|
| Load average > ~3–4 sur 2 cœurs, ou throttle CPU Hostinger récurrent | Upgrade **KVM 4** (4 vCPU / 16 Go) |
| RAM node > 85 % + swap actif + pods Pending | Idem |
| Besoin HA réel (RPO/RTO multi-disque) | 2e nœud **ou** Atlas / Redis managé + `apply-ha` |

Après upgrade ≥16 Go :

```bash
cd /opt/wise-eat && git pull
sudo ./install.sh apply-ha
# Optionnel MinIO SR :
sudo ./install.sh repair-minio-site-replication-k8s
```

## Apply / rollback

```bash
# Snapshot Hostinger recommandé avant
cd /opt/wise-eat && git pull
DRY_RUN=1 sudo k8s/scripts/apply-vps-kvm2-profile.sh   # aperçu
sudo ./install.sh apply-vps-kvm2

# Rollback HA (machine assez grande uniquement)
sudo ./install.sh apply-ha
```

## Smoke post-apply

```bash
curl -sI https://apis.wise-eat.com/health
curl -sI https://api.wise-eat.com/health
curl -sI https://ws.wise-eat.com/api/health
kubectl -n wise-eat get hpa,deploy
kubectl -n wise-eat get deploy -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas | grep -E 'replica|emqx-[23]|minio-replica'
# Attendu : DESIRED 0 pour les lignes HA
```

## Alertes Prometheus

Seuils pods down alignés HPA min 1 :

- `AfricaMealsApiPodsDown` : available **< 1**
- `AfricaMealsWsPodsDown` : available **< 1**
