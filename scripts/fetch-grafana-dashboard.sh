#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DASH_ROOT="${MON_DIR}/grafana/dashboards"
CORE_SYSTEM_DIR="${DASH_ROOT}/Core System"
mkdir -p "${DASH_ROOT}/Redis" "${DASH_ROOT}/Memcached" "${CORE_SYSTEM_DIR}"

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
  curl -fsSL "https://grafana.com/api/dashboards/1860/revisions/latest/download" -o "${out}.tmp"
  python3 - <<'PY' "${out}.tmp" "${out}"
import json, sys

src, dst = sys.argv[1], sys.argv[2]
PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}

with open(src, encoding="utf-8") as f:
    dash = json.load(f)

dash["id"] = None
dash["uid"] = "wise-eat-node-1860"
dash["title"] = "Wise Eat — System (Node Exporter)"

repl = json.dumps(dash)
repl = repl.replace("${ds_prometheus}", PROM_UID)
repl = repl.replace('"uid": "${ds_prometheus}"', f'"uid": "{PROM_UID}"')
repl = repl.replace("${DS_PROMETHEUS}", "Prometheus")
repl = repl.replace("${DS_PROM}", PROM_UID)
dash = json.loads(repl)

for key in ("__inputs", "__requires", "__elements"):
    dash.pop(key, None)

def fix_ds(obj):
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if ds in ("Prometheus", "${DS_PROMETHEUS}", "${ds_prometheus}"):
            obj["datasource"] = DS
        elif isinstance(ds, dict) and ds.get("uid") in ("${ds_prometheus}", "Prometheus"):
            obj["datasource"] = DS
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)

fix_ds(dash)

# Variable datasource « Prometheus » (uid prometheus) — retrait du sélecteur ds_prometheus.
templating = dash.get("templating", {}).get("list", [])
dash["templating"]["list"] = [
    v for v in templating if v.get("name") != "ds_prometheus"
]
for var in dash["templating"]["list"]:
    if var.get("datasource"):
        var["datasource"] = DS
    q = var.get("query")
    if isinstance(q, dict) and "datasource" in q:
        q["datasource"] = DS

with open(dst, "w", encoding="utf-8") as f:
    json.dump(dash, f, indent=2)
    f.write("\n")
PY
  rm -f "${out}.tmp"
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

fetch_redis_dashboard
fetch_memcached_dashboard
fetch_node_dashboard
fetch_docker_dashboard
patch_dashboards

rm -rf "${DASH_ROOT}/System"

# Ancien chemin plat (avant foldersFromFilesStructure).
rm -f "${DASH_ROOT}/redis-prometheus.json"
