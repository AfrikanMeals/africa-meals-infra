# Migration EMQX Docker → K8s

## Objectif

Remplacer les conteneurs Docker `wise-eat-emqx-{1,2,3}` par des pods k3s :

| Nœud | Rôle | Host ports | Volume hostPath |
|------|------|------------|-----------------|
| `emqx-1` | Primary | `:1883` MQTT, `:8083` WS, `:18083` dashboard | `/opt/wise-eat/emqx/data-emqx-1` |
| `emqx-2` | Réplica | (cluster interne) | `…/data-emqx-2` |
| `emqx-3` | Réplica | (cluster interne) | `…/data-emqx-3` |

- **Node names** : `emqx@wise-eat-emqx-{1,2,3}` (inchangés — Mnesia)
- **DNS cluster** : Services headless `wise-eat-emqx-{1,2,3}` (plus réseau Docker)
- **Cookie / dashboard** : Secret `emqx-config` ← `.env.emqx`
- **Users MQTT** : `wise-eat-mqtt` / `wise-eat-admin` dans Mnesia + `bootstrap-emqx-auth`
- **API / WS** : `mqtts://host.k3s.internal:8883` (nginx → `127.0.0.1:1883`) — **pas de changement de config**
- **Grafana** : primary `127.0.0.1:18083` ; réplicas via `emqx-docker.json` (pod IPs k8s)

## Cutover (prod)

```bash
cd /opt/wise-eat && git pull
chmod +x k8s/scripts/migrate-emqx-docker-to-k8s.sh \
         k8s/scripts/create-emqx-secret.sh

# Dry-run
sudo k8s/scripts/migrate-emqx-docker-to-k8s.sh --dry-run

# Cutover (backup tar + stop Docker + apply + auth + Prometheus)
sudo ./install.sh migrate-emqx-k8s
```

Si pods `Pending` (mémoire requests ~96 %) :

```bash
kubectl describe node | grep -A6 'Allocated resources'
# Baisser temporairement requests EMQX à 128Mi (après patch LimitRange min) si besoin
```

## Vérifications

```bash
curl -sf http://127.0.0.1:18083/api/v5/status
kubectl -n wise-eat get pods -l app.kubernetes.io/name=emqx -o wide
kubectl -n wise-eat exec deploy/emqx-1 -- /opt/emqx/bin/emqx ctl cluster status

# Prometheus / Grafana
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up{job="emqx"}' | head -c 400
cat /opt/wise-eat/monitoring/prometheus/targets/emqx-docker.json

# MQTTS public (inchangé)
# openssl s_client -connect broker.wise-eat.com:8883 </dev/null
# Dashboard : https://worker.wise-eat.com

# Smoke WS/API temps réel (commande / présence) après cutover
```

Resync cibles Prometheus :

```bash
sudo ./scripts/sync-emqx-prometheus-targets.sh
# ou
sudo ./install.sh repair-emqx-prometheus
```

## Apply sans cutover

```bash
sudo ./install.sh emqx-k8s
```

## Rollback

```bash
kubectl -n wise-eat scale deploy/emqx-1 deploy/emqx-2 deploy/emqx-3 --replicas=0
# attendre ports 1883/8083/18083 libres (~30s)

cd /opt/wise-eat/emqx
set -a && source .env.emqx && set +a
docker compose --env-file .env.emqx up -d

# Remettre file_sd Docker si besoin
sudo ./scripts/sync-emqx-prometheus-targets.sh
```

Restaurer un backup tar (si besoin) :

```bash
cd /opt/wise-eat/emqx
# scale pods = 0 d'abord
tar -xzf backups/emqx-data-YYYYMMDD-HHMMSS.tar.gz
chown -R 1000:1000 data-emqx-1 data-emqx-2 data-emqx-3
```

## Interdits

- `docker compose down -v` ou wipe `data-emqx-*`
- Relancer `install.sh emqx` (Docker) alors que les pods hostPort sont Ready
- Changer `EMQX_ERLANG_COOKIE` / node names au cutover
- Deux writers primary (Docker Up + pod Ready sur `:1883`)

## Fichiers

- Manifests : `k8s/emqx/`
- Secret : `k8s/scripts/create-emqx-secret.sh`
- Cutover : `k8s/scripts/migrate-emqx-docker-to-k8s.sh`
- Prometheus : `scripts/sync-emqx-prometheus-targets.sh`
