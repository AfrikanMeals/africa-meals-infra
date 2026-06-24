#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OUT="${MON_DIR}/grafana/dashboards/redis-prometheus.json"
mkdir -p "$(dirname "${OUT}")"

curl -fsSL "https://grafana.com/api/dashboards/763/revisions/latest/download" -o "${OUT}.tmp"

python3 - <<'PY' "${OUT}.tmp" "${OUT}"
import json, sys

src, dst = sys.argv[1], sys.argv[2]
PROM_UID = "prometheus"

with open(src, encoding="utf-8") as f:
    dash = json.load(f)

dash["id"] = None
dash["uid"] = "wise-eat-redis-763"

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

for var in dash.get("templating", {}).get("list", []):
    if var.get("name") == "namespace":
        var["current"] = {
            "selected": True,
            "text": "wise-eat",
            "value": "wise-eat",
        }
    if var.get("name") == "instance":
        var["includeAll"] = True
        var["multi"] = True

with open(dst, "w", encoding="utf-8") as f:
    json.dump(dash, f, indent=2)
    f.write("\n")
PY

rm -f "${OUT}.tmp"
log "Dashboard Grafana → ${OUT}"
