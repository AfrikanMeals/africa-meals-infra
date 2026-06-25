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
if curl -sf "http://127.0.0.1:8088/metrics" | grep -q '^container_cpu_usage_seconds_total'; then
  log "OK  cAdvisor (:8088) — métriques conteneurs présentes"
else
  warn "FAIL cAdvisor (:8088) — conteneur wise-eat-cadvisor arrêté ?"
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

log "=== Prometheus targets ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/targets' | grep -q '"health":"up"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/targets' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d.get('data',{}).get('activeTargets',[]):
  j=t.get('labels',{}).get('job','')
  if 'redis' in j or j in ('prometheus', 'memcached', 'node', 'cadvisor', 'minio'):
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
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=container_cpu_usage_seconds_total' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=container_cpu_usage_seconds_total' \
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
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=minio_cluster_health_status' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=minio_cluster_health_status' \
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

log "=== requête up{job=\"minio\"} ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22minio%22%7D' | grep -q '"status":"success"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22minio%22%7D' \
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
  warn "FAIL requête Prometheus up{job=\"minio\"}"
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

if [[ "${fail}" -ne 0 ]]; then
  echo ""
  warn "Correctifs fréquents :"
  echo "  1. Redis : aligner mots de passe dans monitoring/.env.monitoring"
  echo "  2. Memcached : sudo ./install.sh memcached puis vérifier curl :11211"
  echo "  3. MinIO : sudo ./install.sh minio (réseau wise-eat-infra + métriques public)"
  echo "  4. Prometheus : curl -X POST http://127.0.0.1:9090/-/reload"
  echo "  5. Grafana : sudo ./install.sh repair-monitoring (recharge dashboards)"
  echo "  6. cd monitoring && docker compose --env-file .env.monitoring up -d --force-recreate prometheus grafana"
  exit 1
fi

log "Stack monitoring OK — Grafana : Core System / Redis / Memcached / MinIO"
