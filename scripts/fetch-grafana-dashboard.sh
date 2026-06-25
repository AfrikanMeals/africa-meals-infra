#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DASH_ROOT="${MON_DIR}/grafana/dashboards"
CORE_SYSTEM_DIR="${DASH_ROOT}/Core System"
MINIO_DIR_DASH="${DASH_ROOT}/MinIO"
EMQX_DIR_DASH="${DASH_ROOT}/EMQX"
mkdir -p "${DASH_ROOT}/Redis" "${DASH_ROOT}/Memcached" "${CORE_SYSTEM_DIR}" "${MINIO_DIR_DASH}" "${EMQX_DIR_DASH}"

fetch_redis_dashboard() {
  local out="${DASH_ROOT}/Redis/redis-prometheus.json"
  curl -fsSL "https://grafana.com/api/dashboards/763/revisions/latest/download" -o "${out}.tmp"
  python3 - <<'PY' "${out}.tmp" "${out}"
import json, sys

src, dst = sys.argv[1], sys.argv[2]
PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}

with open(src, encoding="utf-8") as f:
    dash = json.load(f)

dash["id"] = None
dash["uid"] = "wise-eat-redis-763"
dash["title"] = "Wise Eat — Redis"

for ds in dash.get("__inputs", []):
    if ds.get("type") == "datasource":
        ds["pluginName"] = "Prometheus"
        ds["pluginId"] = "prometheus"
        ds["name"] = "DS_PROMETHEUS"
        ds["value"] = "Prometheus"

repl = json.dumps(dash)
repl = repl.replace("${DS_PROMETHEUS}", "Prometheus")
repl = repl.replace("${DS_PROM}", PROM_UID)
dash = json.loads(repl)

for key in ("__inputs", "__requires", "__elements"):
    dash.pop(key, None)

dash["templating"] = {
    "list": [
        {
            "name": "job",
            "type": "query",
            "datasource": DS,
            "definition": "label_values(redis_up, job)",
            "query": "label_values(redis_up, job)",
            "refresh": 2,
            "includeAll": True,
            "multi": True,
            "hide": 0,
            "current": {"selected": True, "text": "All", "value": "$__all"},
        },
    ]
}

with open(dst, "w", encoding="utf-8") as f:
    json.dump(dash, f, indent=2)
    f.write("\n")
PY
  rm -f "${out}.tmp"
  log "Dashboard Redis → ${out} (base Grafana.com)"
}

patch_dashboards() {
  python3 "${SCRIPT_DIR}/patch-grafana-dashboards.py" \
    "${DASH_ROOT}/Redis/redis-prometheus.json" \
    "${DASH_ROOT}/Memcached/memcached-prometheus.json"
  log "Dashboards patchés (primary / réplicas)"
}

fetch_memcached_dashboard() {
  local out="${DASH_ROOT}/Memcached/memcached-prometheus.json"
  curl -fsSL "https://grafana.com/api/dashboards/11527/revisions/latest/download" -o "${out}.tmp"
  python3 - <<'PY' "${out}.tmp" "${out}"
import json, sys

src, dst = sys.argv[1], sys.argv[2]
PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}

with open(src, encoding="utf-8") as f:
    dash = json.load(f)

dash["id"] = None
dash["uid"] = "wise-eat-memcached-11527"
dash["title"] = "Wise Eat — Memcached"

repl = json.dumps(dash)
repl = repl.replace("${DS_PROMETHEUS}", "Prometheus")
repl = repl.replace("${DS_PROM}", PROM_UID)
repl = repl.replace('"datasource": "-- Grafana --"', '"datasource": {"type": "grafana", "uid": "grafana"}')
dash = json.loads(repl)

for key in ("__inputs", "__requires", "__elements"):
    dash.pop(key, None)

# Normalise les datasources legacy (string → uid prometheus).
def fix_ds(obj):
    if isinstance(obj, dict):
        if obj.get("datasource") == "Prometheus" or obj.get("datasource") == "${DS_PROMETHEUS}":
            obj["datasource"] = DS
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)

fix_ds(dash)

# Les variables Grafana « All » nécessitent un matcher regex (=~) dans les panneaux.
def fix_job_filters(obj):
    if isinstance(obj, dict):
        for key, val in list(obj.items()):
            if key == "expr" and isinstance(val, str):
                obj[key] = val.replace('job="$job"', 'job=~"$job"')
            else:
                fix_job_filters(val)
    elif isinstance(obj, list):
        for item in obj:
            fix_job_filters(item)

fix_job_filters(dash)

dash["templating"] = {
    "list": [
        {
            "name": "job",
            "type": "query",
            "datasource": DS,
            "definition": "label_values(memcached_up, job)",
            "query": "label_values(memcached_up, job)",
            "refresh": 2,
            "includeAll": True,
            "multi": True,
            "hide": 0,
            "current": {"selected": True, "text": "All", "value": "$__all"},
        },
    ]
}

with open(dst, "w", encoding="utf-8") as f:
    json.dump(dash, f, indent=2)
    f.write("\n")
PY
  rm -f "${out}.tmp"
  log "Dashboard Memcached → ${out} (base Grafana.com)"
}

fetch_node_dashboard() {
  local out="${CORE_SYSTEM_DIR}/node-exporter-full.json"
  local tmp="${out}.tmp"
  curl -fsSL "https://grafana.com/api/dashboards/1860/revisions/latest/download" -o "${tmp}"
  python3 "${SCRIPT_DIR}/patch-grafana-node-dashboard.py" "${tmp}" "${out}"
  rm -f "${tmp}"
  log "Dashboard Node Exporter → ${out} (Grafana.com #1860)"
}

fetch_docker_dashboard() {
  local out="${CORE_SYSTEM_DIR}/docker-monitoring.json"
  local tmp="${out}.tmp"
  curl -fsSL "https://grafana.com/api/dashboards/4271/revisions/latest/download" -o "${tmp}"
  python3 "${SCRIPT_DIR}/patch-grafana-docker-dashboard.py" "${tmp}" "${out}"
  rm -f "${tmp}"
  log "Dashboard Docker → ${out} (Grafana.com #4271)"
}

fetch_minio_dashboard() {
  local out="${MINIO_DIR_DASH}/minio-storage.json"
  local tmp="${out}.tmp"
  # #25202 = version Prometheus du dashboard #20826 (InfluxDB 2.0)
  curl -fsSL "https://grafana.com/api/dashboards/25202/revisions/latest/download" -o "${tmp}"
  python3 "${SCRIPT_DIR}/patch-grafana-minio-dashboard.py" "${tmp}" "${out}"
  rm -f "${tmp}"
  log "Dashboard MinIO → ${out} (Grafana.com #25202, équivalent Prometheus de #20826)"
}

fetch_emqx_dashboard() {
  local out="${EMQX_DIR_DASH}/emqx-mqtt.json"
  local tmp="${out}.tmp"
  curl -fsSL "https://grafana.com/api/dashboards/17446/revisions/latest/download" -o "${tmp}"
  python3 "${SCRIPT_DIR}/patch-grafana-emqx-dashboard.py" "${tmp}" "${out}"
  rm -f "${tmp}"
  log "Dashboard EMQX → ${out} (Grafana.com #17446 — EMQX 5)"
}

fetch_redis_dashboard
fetch_memcached_dashboard
fetch_node_dashboard
fetch_docker_dashboard
fetch_minio_dashboard
fetch_emqx_dashboard
patch_dashboards

rm -rf "${DASH_ROOT}/System"

# Ancien chemin plat (avant foldersFromFilesStructure).
rm -f "${DASH_ROOT}/redis-prometheus.json"
