# africa-meals-ws — production k8s (VPS Wise Eat)

> **Déploiement depuis zéro (VPS `/opt/wise-eat` + `/opt/wise-eat-ws`) : [DEPLOY.md](./DEPLOY.md)**

**3 pods** k3s, services locaux sur le VPS (équivalent `127.0.0.1` via `host.k3s.internal`), **TLS conservé** (SNI Let's Encrypt).  
**PM2 = dev uniquement** — pas de `africa-meals-ws` en PM2 prod sur le VPS.

## Architecture

```
Internet → nginx :443 (wise-eat.cloud / ws.wise-eat.com)
              ↓
         NodePort :30800
              ↓
    Service (sessionAffinity ClientIP, 3 endpoints)
         ↙    ↓    ↘
      Pod 1  Pod 2  Pod 3   restartPolicy: Always
         ↘    ↓    ↙
    host.k3s.internal → Stunnel / EMQX / API sur le VPS
      :6381 Redis   :6382 BullMQ   :27018 MongoDB   :8883 MQTT   :9000 API
```

## Résilience

| Mécanisme | Valeur |
|-----------|--------|
| Replicas | 3 |
| `restartPolicy` | `Always` (redémarrage auto si crash) |
| `maxUnavailable` | 0 (rolling update sans coupure) |
| `PodDisruptionBudget` | `minAvailable: 2` |
| Probes | startup + readiness + liveness sur `/api/health` |
| `preStop` | 10 s (drain connexions WS/STOMP) |
| `terminationGracePeriodSeconds` | 60 |

## Commande de déploiement (production)

### VPS Wise Eat (`/opt/wise-eat` + `/opt/wise-eat-ws`)

Dépôts séparés sur le serveur — le dossier applicatif s’appelle **`wise-eat-ws`**, pas `africa-meals-ws`.

```bash
cd /opt/wise-eat
git pull
chmod +x k8s/scripts/*.sh

# .env explicite (recommandé)
sudo k8s/scripts/deploy-ws-production.sh /opt/wise-eat-ws/.env

# ou auto-détection de /opt/wise-eat-ws/.env
sudo k8s/scripts/deploy-ws-production.sh
```

Prérequis build Docker : `/opt/wise-eat-ws` **et** `/opt/packages` (monorepo partiel avec `africa-meals-proto` + `africa-meals-field-selection`).

### Monorepo local

Sur la racine du monorepo :

```bash
cd /chemin/AfrikaMeals
git pull
chmod +x infra/k8s/scripts/*.sh

sudo infra/k8s/scripts/deploy-ws-production.sh africa-meals-ws/.env
```

Étapes : k3s → build image → secret → 3 pods → nginx `:30800` → sonde health.

Options :

```bash
# k3s déjà installé
sudo infra/k8s/scripts/deploy-ws-production.sh africa-meals-ws/.env --skip-k3s

# nginx déjà basculé
sudo infra/k8s/scripts/deploy-ws-production.sh africa-meals-ws/.env --skip-nginx
```

### Mise à jour (nouvelle version)

```bash
cd /chemin/AfrikaMeals && git pull
sudo infra/k8s/scripts/deploy-ws-production.sh africa-meals-ws/.env --skip-k3s --skip-nginx
```

### Déploiement manuel (étape par étape)

```bash
sudo infra/k8s/scripts/install-k3s.sh
infra/k8s/scripts/build-ws-image.sh
infra/k8s/scripts/create-ws-secret.sh africa-meals-ws/.env
infra/k8s/scripts/deploy-ws.sh --verify
sudo infra/k8s/scripts/patch-nginx-ws-backend.sh
```

## Vérification

```bash
# Santé load-balancée (3 pods)
curl -s http://127.0.0.1:30800/api/health | jq .

# État pods (attendu: 3/3 Running)
sudo k3s kubectl get pods -n wise-eat -l app.kubernetes.io/name=africa-meals-ws -o wide

# PDB
sudo k3s kubectl get pdb -n wise-eat

# Logs (Redis adapter + BullMQ requis)
sudo k3s kubectl logs -n wise-eat -l app.kubernetes.io/name=africa-meals-ws --tail=30 | grep -E 'Redis|BullMQ|STOMP|listening'

# Simuler failover — supprimer un pod, k8s le recrée
sudo k3s kubectl delete pod -n wise-eat -l app.kubernetes.io/name=africa-meals-ws --field-selector=status.phase=Running | head -1
sudo k3s kubectl get pods -n wise-eat -w
```

## Variables d'environnement

### ConfigMap (non sensible)

Connexion **locale VPS** via `host.k3s.internal` (= services sur `127.0.0.1` de l'hôte) + ports **Stunnel / nginx stream** :

| Service | Host pod | Port | TLS SNI |
|---------|----------|------|---------|
| Redis cache | `host.k3s.internal` | 6381 (+6383/6384) | `cache.wise-eat.com` |
| Redis BullMQ | `host.k3s.internal` | 6382 (+6385/6386) | `cache.wise-eat.com` |
| Memcached | `host.k3s.internal` | 11212 (+11213/11214) | `cache.wise-eat.com` |
| MongoDB | `host.k3s.internal` | 27018 | cert LE `db.wise-eat.com` |
| MQTT | `host.k3s.internal` | 8883 | `broker.wise-eat.com` |
| API Nest | `host.k3s.internal` | 9000 | — |

### Secret (depuis `.env`)

`create-ws-secret.sh` extrait JWT, mots de passe, `MONGODB_URI`, URLs Redis/BullMQ et réécrit `*.wise-eat.com` → `host.k3s.internal`.

Modèle : `africa-meals-ws/secret.env.example`

## PM2 vs k8s

| Environnement | WS |
|---------------|-----|
| **Dev local** | PM2 (`npm run pm2:dev`) |
| **Prod VPS** | k3s (3 pods) — **ne pas** `pm2 start africa-meals-ws` |

## Dépannage

**Pod CrashLoopBackOff** — logs bootstrap :

```bash
sudo k3s kubectl logs -n wise-eat deployment/africa-meals-ws --tail=80
```

Causes fréquentes : secret absent, Redis/Mongo injoignables, `JWT_SECRET` manquant.

**TLS Redis/MQTT** — vérifier SNI dans les logs ; ne pas mettre `REDIS_TLS_REJECT_UNAUTHORIZED=false` en prod.

**`host.k3s.internal` introuvable** (`ENOTFOUND`) — ce nom n'existe pas nativement sur k3s bare-metal (réservé à k3d). Le déploiement injecte `hostAliases` sur les pods WS (recommandé) :

```bash
sudo k8s/scripts/ensure-k3s-host-gateway.sh
```

Les pods WS résolvent `host.k3s.internal` via `/etc/hosts`, **sans CoreDNS**. Un `kubectl run dns-test` échouera encore — c'est normal.

**Mongo/Redis `ECONNRESET` vers `2.x.x.x:27018`** — `host.k3s.internal` pointe vers l’**IP publique** du nœud (hairpin NAT). Le script mappe désormais vers **cni0** (souvent `10.42.0.1`) :

```bash
ip -4 addr show cni0   # noter l’IP (ex. 10.42.0.1)
sudo k8s/scripts/ensure-k3s-host-gateway.sh
kubectl -n wise-eat exec deploy/africa-meals-ws -- getent hosts host.k3s.internal
# attendu : 10.42.0.1  host.k3s.internal  (pas l’IP publique)
```

Override manuel : `sudo K3S_HOST_GATEWAY_IP=10.42.0.1 k8s/scripts/ensure-k3s-host-gateway.sh`

**CoreDNS `Connection refused`** (après une ancienne version du script) :

```bash
sudo k8s/scripts/ensure-k3s-host-gateway.sh --repair-coredns
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

**nginx** — backend WS :

```bash
sudo WS_BACKEND_PORT=30800 infra/k8s/scripts/patch-nginx-ws-backend.sh
```

## Headlamp — UI Kubernetes (`k8s.wise-eat.com`)

[Headlamp](https://headlamp.dev/) (CNCF) : gestion pods, logs, exec, déploiements — gratuit et adapté k3s.

| Couche | Auth |
|--------|------|
| HTTPS | Let's Encrypt |
| Headlamp | token ServiceAccount `headlamp-admin` (pas de basic auth nginx — incompatible Bearer) |

**DNS** : `k8s.wise-eat.com` → A/AAAA VPS (**DNS only** Cloudflare).

```bash
cd /opt/wise-eat && git pull
chmod +x k8s/scripts/*.sh

sudo STUNNEL_TLS_EMAIL=help@wise-eat.com k8s/scripts/deploy-k8s-dashboard.sh
# ou si déjà déployé, corriger nginx :
sudo k8s/scripts/install-k8s-nginx.sh
```

Connexion :

1. Ouvrir `https://k8s.wise-eat.com/` (plus de popup basic auth)
2. Headlamp → **Token** → coller le token :
   ```bash
   sudo k8s/scripts/create-headlamp-admin-token.sh
   ```

## africa-meals-api — production k8s

> **Guide complet : [DEPLOY-API.md](./DEPLOY-API.md)**

**5 pods**, **512 Mi RAM** / pod (≈ 2,5 Gi total), NodePort **30900**, nginx **api.wise-eat.com**.

```bash
# VPS
sudo k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod

# Monorepo
sudo infra/k8s/scripts/deploy-api-production.sh africa-meals-api/.env.prod
```

Grafana : dossier **Servers** → **Africa Meals API (k8s)**  
Headlamp : namespace `wise-eat` → deployment `africa-meals-api`

## Fichiers

```
infra/k8s/
  Dockerfile.africa-meals-ws
  Dockerfile.africa-meals-api
  africa-meals-ws/
    configmap.yaml          # host.k3s.internal + TLS SNI
    deployment.yaml         # 3 replicas, probes, preStop
    service.yaml            # NodePort 30800
    poddisruptionbudget.yaml
    secret.env.example
  africa-meals-api/
    configmap.yaml          # overrides k8s (512 Mi, pools, WS interne)
    deployment.yaml         # 5 replicas, 512 Mi, probes
    service.yaml            # NodePort 30900
    poddisruptionbudget.yaml
    secret.env.example
  headlamp/                 # UI Kubernetes (NodePort 30850)
  scripts/
    deploy-ws-production.sh # WS — commande principale
    deploy-api-production.sh # API — commande principale
    deploy-k8s-dashboard.sh # Headlamp + k8s.wise-eat.com
    install-headlamp.sh
    install-k8s-nginx.sh
    create-headlamp-admin-token.sh
    deploy-ws.sh
    create-ws-secret.sh
    build-ws-image.sh
    install-k3s.sh
    patch-nginx-ws-backend.sh
```
