# Déploiement africa-meals-api — VPS Wise Eat (k8s)

Guide pour **3 pods k8s (1 Gi RAM)**, **https://api.wise-eat.com**, monitoring Grafana dossier **Servers**, visibilité **Headlamp**.

## Layout VPS

| Chemin | Dépôt |
|--------|--------|
| `/opt/wise-eat` | infra (k8s, nginx, monitoring) |
| `/opt/wise-eat-api` | africa-meals-api (NestJS) |
| `/opt/packages` | `africa-meals-proto` + `africa-meals-field-selection` |

PM2 = **dev local uniquement**. Production API = **k3s** (comme WS).

---

## Prérequis

- k3s + **africa-meals-ws** déjà déployé (namespace `wise-eat`, Stunnel Redis/Mongo/MQTT actifs)
- DNS `api.wise-eat.com` → IP VPS (Cloudflare Proxied OK)
- Fichier `/opt/wise-eat-api/.env.prod` (modèle : `africa-meals-api/.env.prod` du monorepo)
- `accounts.json` Firebase à côté du `.env.prod` (optionnel)

---

## Déploiement complet

```bash
cd /opt/wise-eat
git pull
chmod +x k8s/scripts/*.sh

sudo STUNNEL_TLS_EMAIL=help@wise-eat.com \
  k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod
```

Étapes :

1. k3s (si absent)
2. kube-state-metrics
3. Build image Docker + import k3s
4. Secrets K8s (`.env.prod` + `accounts.json`)
5. **3 pods — 1 Gi RAM**, `restartPolicy: Always`, PDB `minAvailable: 2`
6. Patch WS → API interne (`africa-meals-api.wise-eat.svc.cluster.local:9000`)
7. Cibles Prometheus `/api/metrics`
8. nginx `api.wise-eat.com` → NodePort `:30900`

---

## Vérification

```bash
curl -s http://127.0.0.1:30900/api/health | jq .
curl -s http://127.0.0.1:30900/api/metrics | head -20
curl -s https://api.wise-eat.com/api/health | jq .

sudo k3s kubectl get pods -n wise-eat -l app.kubernetes.io/name=africa-meals-api -o wide
sudo k3s kubectl get pdb -n wise-eat
```

### Failover (redémarrage auto)

```bash
sudo k3s kubectl delete pod -n wise-eat -l app.kubernetes.io/name=africa-meals-api --field-selector=status.phase=Running | head -1
sudo k3s kubectl get pods -n wise-eat -w
```

---

## Headlamp

UI : **https://k8s.wise-eat.com** (token SA admin)

- Namespace **`wise-eat`** → deployments `africa-meals-api` + `africa-meals-ws`
- Logs, exec, scale, événements pods

```bash
sudo k8s/scripts/create-headlamp-admin-token.sh
```

---

## Grafana (dossier Servers)

Dashboard : **`Africa Meals API (k8s)`**

```
/opt/wise-eat/monitoring/grafana/dashboards/Servers/africa-meals-api-k8s.json
```

```bash
sudo k8s/scripts/repair-api-prometheus.sh
docker restart wise-eat-grafana
```

Console : `https://console.wise-eat.com` → **Servers**

Alertes : `monitoring/prometheus/alerts/africa-meals-api.yml`

---

## Mise à jour

```bash
cd /opt/wise-eat-api && git pull
cd /opt/wise-eat && git pull

sudo k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod \
  --skip-k3s --skip-tls
```

---

## Ressources par pod

| Paramètre | Valeur |
|-----------|--------|
| RAM request/limit | **1 Gi** |
| CPU request | 200m |
| CPU limit | 2 cores |
| Replicas | 3 |
| NodePort | **30900** |
| PDB | min 2 pods sur 3 |
| Probes | `/api/health` (startup + readiness + liveness) |

---

## Dépannage

| Symptôme | Action |
|----------|--------|
| CrashLoop | `kubectl logs -n wise-eat deployment/africa-meals-api --tail=100` |
| 502 api.wise-eat.com | `curl 127.0.0.1:30900/api/health` + `patch-nginx-api-backend.sh` |
| Grafana vide | `repair-api-prometheus.sh` + restart Grafana |
| Atlas au lieu de Stunnel | utiliser `.env.prod` avec `host.k3s.internal:27018` |
