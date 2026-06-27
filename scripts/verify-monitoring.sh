#!/usr/bin/env bash
# Vérifie Prometheus + redis_exporter + memcached_exporter (diagnostic Grafana vide).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

cd "${MON_DIR}"

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    log "OK  ${label}"
    return 0
  fi
  warn "FAIL ${label}"
  return 1
}

fail=0

log "=== Node exporter (hôte VPS) ==="
if curl -sf "http://127.0.0.1:9100/metrics" | grep -q '^node_cpu_seconds_total'; then
  log "OK  node_exporter (:9100) — métriques CPU présentes"
else
  warn "FAIL node_exporter (:9100) — conteneur wise-eat-node-exporter arrêté ?"
  fail=1
fi

log "=== cAdvisor (conteneurs Docker) ==="
cadvisor_metrics_ok() {
  local metrics
  metrics="$(curl -sf "http://127.0.0.1:8088/metrics" 2>/dev/null || true)"
  [[ -n "${metrics}" ]] || return 1
  echo "${metrics}" | grep '^container_cpu_usage_seconds_total' | grep -v 'id="/"' | grep -q .
}
if cadvisor_metrics_ok; then
  log "OK  cAdvisor (:8088) — métriques conteneurs présentes"
elif docker exec wise-eat-cadvisor wget -qO- http://127.0.0.1:8080/metrics 2>/dev/null \
  | grep '^container_cpu_usage_seconds_total' | grep -v 'id="/"' | grep -q .; then
  log "OK  cAdvisor (réseau Docker) — métriques conteneurs présentes (:8088 host injoignable)"
else
  warn "FAIL cAdvisor — pas de métriques conteneur (seulement id=\"/\" ou vide)"
  warn "      Recréer : sudo ./install.sh repair-monitoring"
  if docker ps --format '{{.Names}}' | grep -qx 'wise-eat-cadvisor'; then
    warn "      Logs cAdvisor (dernières lignes) :"
    docker logs wise-eat-cadvisor --tail 15 2>&1 | sed 's/^/        /' || true
    storage_driver="$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')"
    if [[ "${storage_driver}" == "overlayfs" ]]; then
      warn "      Storage Driver=overlayfs (Docker 29+) — compose impose --disable_metrics=disk (cadvisor#3860)"
    fi
  fi
  fail=1
fi

log "=== Ollama (ollama-exporter) ==="
if curl -sf "http://127.0.0.1:9400/metrics" 2>/dev/null | grep -q '^ollama_up '; then
  log "OK  ollama-exporter (:9400) — métriques ollama_* exposées"
else
  warn "FAIL ollama-exporter (:9400) — conteneur wise-eat-ollama-exporter arrêté ?"
  fail=1
fi
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=ollama_up{job="ollama"}' | grep -q '"value":\["' ; then
  up=$(curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=ollama_up{job="ollama"}' \
    | python3 -c "import json,sys; r=json.load(sys.stdin).get('data',{}).get('result',[]); print(r[0]['value'][1] if r else '?')")
  if [[ "${up}" == "1" ]]; then
    log "OK  Prometheus ollama_up=1 (job=ollama)"
  else
    warn "FAIL Prometheus ollama_up=${up} — Ollama injoignable depuis ollama-exporter ?"
    fail=1
  fi
else
  warn "FAIL job ollama absent dans Prometheus — sudo ./install.sh monitoring"
  fail=1
fi

log "=== Redis exporters (host) ==="
for pair in "9121:cache" "9122:bullmq"; do
  port="${pair%%:*}"
  name="${pair##*:}"
  if curl -sf "http://127.0.0.1:${port}/metrics" | grep -q '^redis_up '; then
    up=$(curl -sf "http://127.0.0.1:${port}/metrics" | awk '/^redis_up /{print $2; exit}')
    if [[ "${up}" == "1" ]]; then
      log "OK  exporter ${name} (:${port}) redis_up=1"
    else
      warn "FAIL exporter ${name} (:${port}) redis_up=${up} — mot de passe Redis / ACL ?"
      fail=1
    fi
  else
    warn "FAIL exporter ${name} (:${port}) — pas de métrique redis_up"
    fail=1
  fi
done

log "=== Memcached exporter (host) ==="
if curl -sf "http://127.0.0.1:9150/metrics" | grep -q '^memcached_up '; then
  up=$(curl -sf "http://127.0.0.1:9150/metrics" | awk '/^memcached_up /{print $2; exit}')
  if [[ "${up}" == "1" ]]; then
    log "OK  exporter memcached (:9150) memcached_up=1"
  else
    warn "FAIL exporter memcached (:9150) memcached_up=${up} — Memcached injoignable sur :${MEMCACHED_PORT:-11211} ?"
    fail=1
  fi
else
  warn "FAIL exporter memcached (:9150) — pas de métrique memcached_up"
  fail=1
fi

log "=== MinIO (métriques cluster) ==="
MINIO_PORT="${MINIO_API_PORT:-9000}"
if curl -sf "http://127.0.0.1:${MINIO_PORT}/minio/health/live" >/dev/null 2>&1; then
  cluster_ok=0
  node_ok=0
  if curl -sf "http://127.0.0.1:${MINIO_PORT}/minio/v2/metrics/cluster" | grep -q '^minio_cluster_health_status'; then
    cluster_ok=1
  fi
  if curl -sf "http://127.0.0.1:${MINIO_PORT}/minio/v2/metrics/node" | grep -q '^minio_node_process_cpu_total_seconds'; then
    node_ok=1
  fi
  if [[ "${cluster_ok}" -eq 1 && "${node_ok}" -eq 1 ]]; then
    log "OK  MinIO (:${MINIO_PORT}) — métriques cluster + node exposées"
  else
    warn "FAIL MinIO (:${MINIO_PORT}) — cluster=${cluster_ok} node=${node_ok}"
    warn "      Recréer MinIO : sudo ./install.sh minio (MINIO_PROMETHEUS_AUTH_TYPE=public)"
    fail=1
  fi
  if ! docker inspect wise-eat-minio --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
    | grep -q 'wise-eat-infra'; then
    warn "FAIL MinIO — conteneur absent du réseau wise-eat-infra (Prometheus ne peut pas scraper)"
    warn "      sudo docker network connect wise-eat-infra wise-eat-minio"
    fail=1
  fi
else
  warn "FAIL MinIO (:${MINIO_PORT}) — conteneur wise-eat-minio arrêté ?"
  fail=1
fi

log "=== EMQX (métriques Prometheus) ==="
EMQX_DASH_PORT="${EMQX_DASHBOARD_PORT:-18083}"
if curl -sf "http://127.0.0.1:${EMQX_DASH_PORT}/api/v5/prometheus/stats" | grep -q '^emqx_'; then
  log "OK  EMQX primary (:${EMQX_DASH_PORT}) — métriques emqx_* exposées"
else
  warn "FAIL EMQX (:${EMQX_DASH_PORT}) — conteneur wise-eat-emqx-1 arrêté ou Prometheus désactivé ?"
  warn "      sudo ./install.sh emqx"
  fail=1
fi
if docker ps --format '{{.Names}}' | grep -q '^wise-eat-emqx-1$'; then
  if ! docker inspect wise-eat-emqx-1 --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
    | grep -q 'wise-eat-infra'; then
    warn "FAIL EMQX — conteneur absent du réseau wise-eat-infra (Prometheus ne peut pas scraper)"
    warn "      sudo ./install.sh emqx"
    fail=1
  fi
fi

log "=== Prometheus targets ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/targets' | grep -q '"health":"up"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/targets' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d.get('data',{}).get('activeTargets',[]):
  j=t.get('labels',{}).get('job','')
  if 'redis' in j or j in ('prometheus', 'memcached', 'node', 'cadvisor', 'ollama', 'minio', 'minio-cluster', 'minio-node', 'emqx'):
    print(f\"  {j}: {t.get('health')} — {t.get('scrapeUrl')}\")
"
else
  warn "FAIL Prometheus :9090 injoignable"
  fail=1
fi

log "=== requête redis_up ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=redis_up' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=redis_up' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — targets DOWN ou pas encore scrapées)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  job={m.get('job')} instance={m.get('instance')} value={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus redis_up"
  fail=1
fi

log "=== requête container_cpu (dashboard Docker #4271) ==="
CADVISOR_Q='container_cpu_usage_seconds_total{job="cadvisor", instance="wise-eat:8080", id!="/", cpu="total"}'
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=${CADVISOR_Q}" | grep -q '"status":"success"'; then
  curl -sfG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=${CADVISOR_Q}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — job cadvisor non scrapé)')
else:
  cadvisor=[s for s in r if s.get('metric',{}).get('instance')=='wise-eat:8080']
  print(f'  {len(r)} série(s) total, {len(cadvisor)} sur instance wise-eat:8080')
"
else
  warn "FAIL requête Prometheus container_cpu_usage_seconds_total"
  fail=1
fi

log "=== requête up{job=\"cadvisor\"} ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22cadvisor%22%7D' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22cadvisor%22%7D' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — wise-eat-cadvisor arrêté ?)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus up{job=\"cadvisor\"}"
  fail=1
fi

log "=== requête count conteneurs (dashboard Docker #4271 — panel Containers) ==="
CONTAINER_COUNT_Q='count(count by (name) (container_cpu_usage_seconds_total{job="cadvisor", instance="wise-eat:8080", id!="/", cpu="total"}))'
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=${CONTAINER_COUNT_Q}" | grep -q '"status":"success"'; then
  curl -sfG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=${CONTAINER_COUNT_Q}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — panel Containers afficherait N/A)')
    sys.exit(1)
v=r[0].get('value',[None,'?'])[1]
print(f'  conteneurs wise-eat : {v}')
"
else
  warn "FAIL requête Prometheus container_last_seen count"
  fail=1
fi

log "=== requête node_uname_info (dashboard #1860) ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=node_uname_info' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=node_uname_info' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — job node non scrapé)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  job={m.get('job')} nodename={m.get('nodename')} instance={m.get('instance')}\")
"
else
  warn "FAIL requête Prometheus node_uname_info"
  fail=1
fi

log "=== requête up{job=\"node\"} ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — wise-eat-node-exporter arrêté ?)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus up{job=\"node\"}"
  fail=1
fi

log "=== requête memcached_up ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=memcached_up' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=memcached_up' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — target memcached DOWN ou pas encore scrapée)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  job={m.get('job')} instance={m.get('instance')} value={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus memcached_up"
  fail=1
fi

log "=== requête minio_cluster_health_status (dashboard MinIO #20826) ==="
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=minio_cluster_health_status{job=~"minio-cluster|minio-node|minio"}' | grep -q '"status":"success"'; then
  curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=minio_cluster_health_status{job=~"minio-cluster|minio-node|minio"}' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — job minio DOWN ou MinIO non sur wise-eat-infra)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  job={m.get('job')} instance={m.get('instance')} value={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus minio_cluster_health_status"
  fail=1
fi

log "=== requête up{job=~\"minio-cluster|minio-node\"} ==="
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job=~"minio-cluster|minio-node|minio"}' | grep -q '"status":"success"'; then
  curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=up{job=~"minio-cluster|minio-node|minio"}' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — target minio non scrapée)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus up{job=~\"minio-cluster|minio-node\"}"
  fail=1
fi

log "=== requête minio_node_process_cpu_total_seconds ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=minio_node_process_cpu_total_seconds' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=minio_node_process_cpu_total_seconds' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — ajouter scrape /minio/v2/metrics/node dans prometheus.yml)')
else:
    print(f'  {len(r)} série(s) minio_node_*')
"
else
  warn "FAIL requête Prometheus minio_node_process_cpu_total_seconds"
  fail=1
fi

log "=== requête emqx_connections_count (dashboard EMQX #17446) ==="
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=emqx_connections_count{job="emqx"}' | grep -q '"status":"success"'; then
  curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=emqx_connections_count{job="emqx"}' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — job emqx DOWN ou EMQX non installé)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} connections={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus emqx_connections_count"
  fail=1
fi

log "=== requête up{job=\"emqx\"} ==="
if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=up{job="emqx"}' | grep -q '"status":"success"'; then
  curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=up{job="emqx"}' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
if not r:
    print('  (aucune série — target emqx non scrapée)')
else:
    for s in r:
        m=s.get('metric',{})
        print(f\"  instance={m.get('instance')} up={s.get('value',[None,-1])[1]}\")
"
else
  warn "FAIL requête Prometheus up{job=\"emqx\"}"
  fail=1
fi

if command -v k3s >/dev/null 2>&1; then
  log "=== africa-meals-ws (k8s) ==="
  if curl -sf --max-time 5 "http://127.0.0.1:30800/api/metrics" | grep -q ws_up; then
    log "OK  WS NodePort :30800 /api/metrics"
  else
    warn "FAIL WS NodePort 30800 — pods k8s down ?"
    fail=1
  fi
  if curl -sf --max-time 5 "http://127.0.0.1:30080/metrics" 2>/dev/null | grep -q kube_; then
    log "OK  kube-state-metrics :30080"
  else
    warn "FAIL kube-state-metrics :30080 — sudo k8s/scripts/install-kube-state-metrics.sh"
    fail=1
  fi
  prom_mode="$(docker inspect wise-eat-prometheus -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  if [[ "${prom_mode}" != "host" ]]; then
    warn "FAIL Prometheus pas en network_mode=host (scrape k8s bloqué) — sudo k8s/scripts/recreate-prometheus-host.sh"
    fail=1
  else
    log "OK  Prometheus network_mode=host"
  fi
  if curl -sfG 'http://127.0.0.1:9090/api/v1/query' \
    --data-urlencode 'query=ws_up' | grep -q '"value":\["'; then
    log "OK  Prometheus ws_up présent"
  else
    warn "FAIL ws_up absent — sudo k8s/scripts/repair-ws-prometheus.sh"
    fail=1
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  echo ""
  warn "Correctifs fréquents :"
  echo "  1. Redis : aligner mots de passe dans monitoring/.env.monitoring"
  echo "  2. Memcached : sudo ./install.sh memcached puis vérifier curl :11211"
  echo "  3. MinIO Prometheus : sudo ./install.sh repair-minio-prometheus"
  echo "  4. MinIO : sudo ./install.sh minio (réseau wise-eat-infra + métriques public)"
  echo "  5. EMQX : sudo ./install.sh repair-emqx-prometheus"
  echo "  6. Prometheus : curl -X POST http://127.0.0.1:9090/-/reload"
  echo "  7. Grafana : sudo ./install.sh repair-monitoring (recharge dashboards)"
  echo "  8. cd monitoring && docker compose --env-file .env.monitoring up -d --force-recreate prometheus grafana"
  echo "  9. WS k8s Grafana : sudo k8s/scripts/repair-ws-prometheus.sh && docker restart wise-eat-grafana"
  exit 1
fi

log "Stack monitoring OK — Grafana : Core System / Redis / Memcached / MinIO / EMQX"
