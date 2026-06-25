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

log "=== Prometheus targets ==="
if curl -sf 'http://127.0.0.1:9090/api/v1/targets' | grep -q '"health":"up"'; then
  curl -sf 'http://127.0.0.1:9090/api/v1/targets' \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d.get('data',{}).get('activeTargets',[]):
  j=t.get('labels',{}).get('job','')
  if 'redis' in j or j in ('prometheus','memcached','node'):
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

if [[ "${fail}" -ne 0 ]]; then
  echo ""
  warn "Correctifs fréquents :"
  echo "  1. Redis : aligner mots de passe dans monitoring/.env.monitoring"
  echo "  2. Memcached : sudo ./install.sh memcached puis vérifier curl :11211"
  echo "  3. cd monitoring && docker compose --env-file .env.monitoring up -d --force-recreate"
  echo "  4. curl -X POST http://127.0.0.1:9090/-/reload"
  exit 1
fi

log "Stack monitoring OK — Grafana : System / Redis / Memcached"
