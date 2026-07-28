# Loki + Promtail (Wise Eat)

Collecte centralisée des logs → Grafana dossier **Logs**.

| Composant | Conteneur | Port | Rôle |
|-----------|-----------|------|------|
| Loki | `wise-eat-loki` | `127.0.0.1:3100` | Stockage / query (rétention 7j) |
| Promtail | `wise-eat-promtail` | `127.0.0.1:9080` | Agent scrape → push Loki |

## Sources Promtail

1. **Docker** — socket `/var/run/docker.sock` (monitoring, DbGate, exporters, …)
2. **Pods k3s** — `kubernetes_sd` + `/var/log/pods` via kubeconfig `/etc/rancher/k3s/k3s.yaml`
3. **Journal systemd** — nginx, k3s, docker, … (`/var/log/journal`)

Labels utiles : `job` (`docker` \| `kubernetes` \| `journal`), `namespace`, `app`, `container`, `pod`, `unit`.

## Install / update

```bash
cd /opt/wise-eat && git pull
sudo ./install.sh loki
# ou full stack :
sudo ./install.sh monitoring
```

Vérifs :

```bash
curl -sf http://127.0.0.1:3100/ready
curl -sf http://127.0.0.1:9080/ready
curl -sf http://127.0.0.1:3100/loki/api/v1/label/job/values
sudo ./scripts/verify-loki-stack.sh
```

Grafana : `https://console.wise-eat.com` → Dashboards → dossier **Logs** → *Wise Eat — Logs (Loki)*.  
Explore → datasource **Loki** (ex. `{namespace="wise-eat", app="africa-meals-api"}`).

## RAM / disque

- Loki ~384 Mi request (compose `mem_limit`), Promtail ~192 Mi
- Rétention **7 jours** (`limits_config.retention_period`)
- Volume Docker `loki-data` — ne pas `docker compose down -v`

## Rollback

```bash
cd /opt/wise-eat/monitoring
docker compose --env-file .env.monitoring stop loki promtail
# optionnel : rm conteneurs (garde volumes)
docker compose --env-file .env.monitoring rm -f loki promtail
```

Datasource / dashboard : retirer `grafana/provisioning/datasources/loki.yml` + `grafana/dashboards/Logs/` puis recreate Grafana.
