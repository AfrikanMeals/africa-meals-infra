# Déploiement africa-meals-ws — VPS Wise Eat (depuis zéro)

Guide pas à pas pour **3 pods k8s**, **https://ws.wise-eat.com**, **wss://** (STOMP + Socket.IO), monitoring Grafana dossier **Servers**.

## Layout VPS

| Chemin | Dépôt |
|--------|--------|
| `/opt/wise-eat` | infra (Redis, Mongo, EMQX, nginx, monitoring, k8s) |
| `/opt/wise-eat-ws` | africa-meals-ws (NestJS) |
| `/opt/packages` | `africa-meals-proto` + `africa-meals-field-selection` (requis build Docker) |

PM2 = **dev local uniquement**. Production WS = **k3s**.

---

## Phase 0 — Prérequis

### DNS Cloudflare

| Hostname | Type | Proxy |
|----------|------|-------|
| `ws.wise-eat.com` | A → IP VPS | **Proxied OK** (HTTPS/WSS) |
| `cache.wise-eat.com` | A | DNS only (:6381–6386) |
| `broker.wise-eat.com` | A | DNS only (:8883) |
| `db.wise-eat.com` | A | DNS only (:27018) |

### Cloner les dépôts

```bash
ssh root@wise-eat
mkdir -p /opt/packages

git clone https://github.com/AfrikanMeals/africa-meals-infra.git /opt/wise-eat
git clone https://github.com/AfrikanMeals/africa-meals-ws.git /opt/wise-eat-ws
# Packages monorepo (proto + field-selection)
git clone https://github.com/AfrikanMeals/AfrikaMeals.git /tmp/am && \
  cp -a /tmp/am/packages /opt/packages && rm -rf /tmp/am
```

### Fichier `.env` WS

```bash
cp /opt/wise-eat-ws/.env.example /opt/wise-eat-ws/.env
nano /opt/wise-eat-ws/.env   # JWT, Redis, MQTT, MONGODB_URI, secrets…
```

---

## Phase 1 — Infra Docker (Redis, Mongo, EMQX, TLS)

```bash
cd /opt/wise-eat
chmod +x install.sh scripts/*.sh k8s/scripts/*.sh

sudo ./install.sh redis
sudo ./install.sh memcached
sudo ./install.sh emqx
sudo ./install.sh mongodb
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls
sudo ./install.sh verify-tls
sudo ./install.sh monitoring
```

Vérifier :

```bash
curl -sk https://cache.wise-eat.com:6381 2>&1 | head -1   # TLS Redis (timeout OK)
docker ps | grep wise-eat
```

---

## Phase 2 — k3s + WS (3 pods, 512 Mi + swap VPS)

```bash
cd /opt/wise-eat
git pull   # manifests k8s à jour

# Déploiement complet (k3s, kube-state-metrics, image, secret, 3 pods, nginx, Prometheus)
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com \
  k8s/scripts/deploy-ws-production.sh /opt/wise-eat-ws/.env
```

Étapes exécutées :

1. k3s (Traefik off, `fail-swap-on=false`, swap VPS 2 Go)
2. kube-state-metrics (NodePort `:30080`)
3. Build image Docker + import k3s
4. Secret K8s depuis `.env` (host `host.k3s.internal`, TLS SNI)
5. 3 pods — **512 Mi RAM** / pod, `restartPolicy: Always`, PDB `minAvailable: 2`
6. Cibles Prometheus `/api/metrics` par pod
7. nginx `ws.wise-eat.com` → NodePort `:30800` + certificat LE

### Vérification immédiate

```bash
# Interne
curl -s http://127.0.0.1:30800/api/health | jq .
curl -s http://127.0.0.1:30800/api/metrics | head -20

# Public
curl -s https://ws.wise-eat.com/api/health | jq .

# k8s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -n wise-eat -o wide
kubectl get pdb -n wise-eat
```

### WSS (STOMP + Socket.IO)

- STOMP : `wss://ws.wise-eat.com/stomp`
- Socket.IO : `wss://ws.wise-eat.com/socket.io/` (namespace `/chat`)

nginx proxifie déjà `Upgrade` / `Connection` — aucune règle supplémentaire.

---

## Phase 3 — Grafana (dossier Servers)

Le dashboard **`Africa Meals WS (k8s)`** est provisionné depuis :

```
/opt/wise-eat/monitoring/grafana/dashboards/Servers/africa-meals-ws-k8s.json
```

Panels : pods ready, scrape metrics, mémoire 512 Mi, STOMP sessions, WebSocket stats, gRPC p95/erreurs, MQTT, redémarrages k8s.

```bash
cd /opt/wise-eat && git pull

# Réparation complète (Prometheus host network + cibles pods + kube-state-metrics)
sudo k8s/scripts/repair-ws-prometheus.sh
docker restart wise-eat-grafana

# Vérification
curl -sG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=ws_up' | head -c 300
curl -sG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=kube_deployment_status_replicas_available{deployment="africa-meals-ws",namespace="wise-eat"}' | head -c 300
```

Console Grafana : `https://console.wise-eat.com` → dossier **Servers**.

Prometheus alerts : `monitoring/prometheus/alerts/africa-meals-ws.yml`

---

## Phase 4 — Mises à jour

```bash
cd /opt/wise-eat-ws && git pull && npm ci && npm run build
cd /opt/wise-eat && git pull

sudo k8s/scripts/deploy-ws-production.sh /opt/wise-eat-ws/.env \
  --skip-k3s --skip-tls
```

Rolling update sans coupure (`maxUnavailable: 0`).

---

## Ressources par pod

| Paramètre | Valeur |
|-----------|--------|
| RAM request/limit | **512 Mi** |
| CPU request | 100m |
| CPU limit | 1 core |
| Swap VPS | 2 Go (hôte, via `install.sh`) |
| k3s kubelet | `fail-swap-on=false` (pods peuvent utiliser swap hôte) |
| PDB | min 2 pods disponibles sur 3 |

---

## Dépannage

| Symptôme | Action |
|----------|--------|
| Pod CrashLoop | `kubectl logs -n wise-eat deployment/africa-meals-ws --tail=100` |
| 502 ws.wise-eat.com | `kubectl get pods -n wise-eat` + `curl 127.0.0.1:30800/api/health` |
| Grafana « No data » | `git pull` puis `sudo k8s/scripts/repair-ws-prometheus.sh` + `docker restart wise-eat-grafana` (Prometheus doit être en `network_mode=host`) |
| Certificat WS | `sudo STUNNEL_TLS_EMAIL=… k8s/scripts/enable-ws-nginx-ssl.sh` |
| packages manquants | vérifier `/opt/packages/africa-meals-proto` |

---

## Commandes utiles

```bash
# Logs 3 pods
kubectl logs -n wise-eat -l app.kubernetes.io/name=africa-meals-ws -f --tail=50

# Failover test
kubectl delete pod -n wise-eat -l app.kubernetes.io/name=africa-meals-ws --field-selector=status.phase=Running | head -1
kubectl get pods -n wise-eat -w

# Scale (déconseillé — garder 3)
kubectl scale deployment africa-meals-ws -n wise-eat --replicas=3
```
