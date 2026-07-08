# Déploiement africa-meals-api — VPS Wise Eat (k8s)

Guide pour **5 pods k8s (512 Mi RAM/pod ≈ 2,5 Gi total)**, **https://api.wise-eat.com**, monitoring Grafana dossier **Servers**, visibilité **Headlamp**.

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
- `accounts.json` Firebase à côté du `.env.prod` (optionnel, projet **wise-eat-com** / FCM)
- `recaptcha-accounts.json` à côté du `.env.prod` (optionnel, projet **wise-eat-com** / formulaire contact)

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
5. **5 pods — 512 Mi RAM** (≈ 2,5 Gi total), `restartPolicy: Always`, PDB `minAvailable: 3`
6. Patch WS → API interne (`africa-meals-api.wise-eat.svc.cluster.local:9000`)
7. Cibles Prometheus `/api/metrics`
8. nginx `api.wise-eat.com` → NodePort `:30900` (+ TLS Let's Encrypt si `STUNNEL_TLS_EMAIL` défini)

---

## HTTPS / TLS (api.wise-eat.com)

Terminaison TLS sur **nginx** (Let's Encrypt) → backend HTTP **NodePort :30900** (pods k8s).

**Prérequis** : DNS `api.wise-eat.com` → VPS, port **80** ouvert (validation ACME webroot), pods API up sur `:30900`.

```bash
cd /opt/wise-eat && git pull

# Certificat + vhost HTTPS (redirect HTTP → HTTPS, HSTS)
sudo STUNNEL_TLS_EMAIL=help@wise-eat.com k8s/scripts/enable-api-nginx-ssl.sh

# Vérifier
curl -sI https://api.wise-eat.com/api/health | head -8
openssl s_client -connect api.wise-eat.com:443 -servername api.wise-eat.com </dev/null 2>/dev/null | openssl x509 -noout -dates
sudo scripts/verify-tls.sh
```

Renouvellement auto : hook `certbot renew` → `install-api-nginx.sh` (inclus dans `./install.sh certbot`).

Si certificat déjà présent (renouvellement manuel du vhost uniquement) :

```bash
sudo k8s/scripts/install-api-nginx.sh
sudo nginx -t && sudo systemctl reload nginx
```

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
sudo k8s/scripts/repair-grafana-monitoring.sh
```

Console : `https://console.wise-eat.com` → **Servers** → **Africa Meals API (k8s)**

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
| RAM request/limit | **512 Mi** / pod |
| Total cluster API | **≈ 2,5 Gi** (5 × 512 Mi) |
| CPU request | 100m |
| CPU limit | 1 core |
| Replicas | **5** |
| NodePort | **30900** |
| PDB | min **3** pods sur 5 |
| Probes | `/api/health` (startup + readiness + liveness) |

---

## Dépannage

| Symptôme | Action |
|----------|--------|
| CrashLoop Mongo `ECONNREFUSED :27017` | recréer le Secret : `create-api-secret.sh` (réécrit `:27018` Stunnel) |
| CrashLoop Redis `ERR_TLS_CERT_ALTNAME_INVALID` | rebuild API (fix `REDIS_TLS_SERVERNAME`) + rollout restart |
| Grafana node_exporter DOWN | `sudo k8s/scripts/repair-grafana-monitoring.sh` (prometheus.yml → 127.0.0.1) |
| Grafana Servers sans API | `git pull` + `docker restart wise-eat-grafana` |
| 502 api.wise-eat.com | `curl 127.0.0.1:30900/api/health` + `patch-nginx-api-backend.sh` |
| Grafana vide | `repair-api-prometheus.sh` + restart Grafana |
| Atlas au lieu de Stunnel | utiliser `.env.prod` avec `host.k3s.internal:27018` |
| Upload médias `ECONNREFUSED` MinIO `:9000` | `MINIO_ENDPOINT=https://storage.wise-eat.com` dans `.env.prod` (pas `host.k3s.internal:9000`) puis `create-api-secret.sh` + rollout restart |
| reCAPTCHA contact `KEY_MISMATCH` / permission denied | `RECAPTCHA_ENTERPRISE_PROJECT_ID=wise-eat-com`, clé site alignée, vider `RECAPTCHA_ENTERPRISE_API_KEY`, déposer `recaptcha-accounts.json` (SA `@wise-eat-com`) puis `create-api-recaptcha-secret.sh` + rollout restart |
| Upload S3 `signature does not match` | **Retirer les guillemets** de `AWS_SECRET_ACCESS_KEY` dans `.env.prod` (dotenv local les retire, `kubectl --from-env-file` non). Puis `create-api-secret.sh` + rollout API. Diagnostic : `sudo ./scripts/verify-aws-s3-env.sh`. Vérifier aussi horloge VPS (`timedatectl`). **Rotation IAM** si clé exposée. |
