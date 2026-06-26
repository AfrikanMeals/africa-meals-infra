#!/usr/bin/env python3
"""Adapte le dashboard MongoDB #12079 (Percona exporter) pour Wise Eat."""
from __future__ import annotations

import json
import re
import sys

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
MONGO_JOB = "mongodb"
MONGO_INSTANCE = "wise-eat-mongo-1:27017"
NODE_INSTANCE = "wise-eat:9100"

# Fallbacks Percona 0.44 (compatible-mode peut ne pas exposer tous les alias legacy).
METRIC_FALLBACKS: tuple[tuple[str, str], ...] = (
    ("mongodb_instance_uptime_seconds", "mongodb_ss_uptime"),
    ("mongodb_op_counters_total", "mongodb_ss_opcounters"),
    ("mongodb_op_counters_repl_total", "mongodb_ss_opcountersRepl"),
    ("mongodb_network_bytes_total", "mongodb_ss_network_bytes_total"),
    ("mongodb_mongod_replset_oplog_size_bytes", "mongodb_ss_repl_oplogSize"),
)

FORMAT_TO_UNIT = {
    "s": "s",
    "none": "short",
    "bytes": "bytes",
    "decbytes": "decbytes",
    "Bps": "Bps",
    "ops": "ops",
    "percent": "percent",
    "percentunit": "percentunit",
}


def fix_ds(obj) -> None:
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if ds in ("Prometheus", "${DS_PROMETHEUS}", "${DS_PROM}"):
            obj["datasource"] = DS
        elif isinstance(ds, dict) and ds.get("type") == "prometheus":
            obj["datasource"] = DS
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)


def add_metric_fallback(expr: str) -> str:
    for legacy, modern in METRIC_FALLBACKS:
        if legacy in expr and modern not in expr:
            modern_expr = expr.replace(legacy, modern, 1)
            return f"({expr}) or ({modern_expr})"
    return expr


def patch_expr(expr: str) -> str:
    if not expr:
        return expr

    if "mongodb_" in expr and "job=" not in expr:
        if 'instance=~"$env"' in expr:
            expr = re.sub(
                r'\{instance=~"\$env"',
                f'{{job="{MONGO_JOB}",instance=~"$env"',
                expr,
            )
        elif re.search(r"mongodb_\w+\{", expr):
            expr = re.sub(
                r"(mongodb_\w+)\{",
                rf'\1{{job="{MONGO_JOB}",',
                expr,
                count=1,
            )
            if 'instance=~' not in expr:
                expr = re.sub(
                    rf'\{{job="{MONGO_JOB}",',
                    f'{{job="{MONGO_JOB}",instance=~"$env",',
                    expr,
                    count=1,
                )
        else:
            expr = re.sub(
                r"(mongodb_\w+)",
                rf'\1{{job="{MONGO_JOB}",instance=~"$env"}}',
                expr,
                count=1,
            )

    if "node_disk_" in expr and f'instance="{NODE_INSTANCE}"' not in expr:
        # Insérer les labels juste avant [ ou { (évite de couper « _total » en « _tota{l} »).
        expr = re.sub(
            r"(node_disk_[a-z0-9_]+)([\[\{])",
            rf'\1{{instance="{NODE_INSTANCE}",job="node"}}\2',
            expr,
        )

    if "mongodb_" in expr and " or " not in expr:
        expr = add_metric_fallback(expr)

    return expr


def patch_targets(panel: dict) -> None:
    ptype = panel.get("type", "")
    for target in panel.get("targets") or []:
        if not isinstance(target, dict):
            continue
        if isinstance(target.get("expr"), str):
            target["expr"] = patch_expr(target["expr"])
        if ptype in ("stat", "singlestat", "gauge"):
            target["instant"] = True
            target["format"] = "time_series"
            target.pop("step", None)
            target.pop("intervalFactor", None)


def parse_thresholds(raw: str | None) -> dict:
    steps = [{"color": "green", "value": None}]
    if not raw:
        return {"mode": "absolute", "steps": steps}
    parts = [p.strip() for p in str(raw).split(",") if p.strip()]
    colors = ["red", "orange", "green"]
    for i, val in enumerate(parts):
        try:
            steps.append({"color": colors[min(i, len(colors) - 1)], "value": float(val)})
        except ValueError:
            continue
    return {"mode": "absolute", "steps": steps}


def migrate_singlestat(panel: dict) -> None:
    if panel.get("type") != "singlestat":
        return

    fmt = panel.get("format", "none")
    value_name = panel.get("valueName", "current")
    calc = "lastNotNull" if value_name in ("current", "last") else "mean"

    panel["type"] = "stat"
    panel["fieldConfig"] = {
        "defaults": {
            "unit": FORMAT_TO_UNIT.get(fmt, fmt),
            "mappings": [
                {
                    "type": "special",
                    "options": {"null": {"index": 0, "text": "N/A"}},
                }
            ],
            "color": {"mode": "thresholds"},
            "thresholds": parse_thresholds(panel.get("thresholds")),
        },
        "overrides": [],
    }
    panel["options"] = {
        "colorMode": "value" if panel.get("colorValue") else "none",
        "graphMode": "area" if panel.get("sparkline", {}).get("show") else "none",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {"calcs": [calc], "fields": "", "values": False},
        "textMode": "auto",
    }


def migrate_graph(panel: dict) -> None:
    if panel.get("type") != "graph":
        return

    bars = panel.get("bars", False)
    panel["type"] = "timeseries"
    panel.setdefault("fieldConfig", {"defaults": {}, "overrides": []})
    panel["options"] = {
        "legend": {
            "calcs": [],
            "displayMode": "list",
            "placement": "bottom",
            "showLegend": True,
        },
        "tooltip": {"mode": "multi", "sort": "none"},
    }
    if bars:
        panel["fieldConfig"]["defaults"]["custom"] = {
            "drawStyle": "bars",
            "fillOpacity": 80,
            "stacking": {"mode": "none"},
        }


def migrate_panels(panels: list) -> None:
    for panel in panels:
        migrate_singlestat(panel)
        migrate_graph(panel)
        patch_targets(panel)
        nested = panel.get("panels")
        if isinstance(nested, list):
            migrate_panels(nested)


def patch_panel_exprs(obj) -> None:
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            obj["expr"] = patch_expr(obj["expr"])
        for v in obj.values():
            patch_panel_exprs(v)
    elif isinstance(obj, list):
        for item in obj:
            patch_panel_exprs(item)


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        dash = json.load(f)

    dash["id"] = None
    dash["uid"] = "wise-eat-mongodb-12079"
    dash["title"] = "Wise Eat — MongoDB"

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", "Prometheus")
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_panel_exprs(dash)
    migrate_panels(dash.get("panels") or [])

    dash["templating"] = {
        "list": [
            {
                "name": "env",
                "label": "env",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(mongodb_up{{job="{MONGO_JOB}"}}, instance)',
                "query": f'label_values(mongodb_up{{job="{MONGO_JOB}"}}, instance)',
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "hide": 0,
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
            {
                "name": "interval",
                "type": "interval",
                "auto": True,
                "auto_count": 30,
                "auto_min": "10s",
                "refresh": 2,
                "query": "1m,10m,30m,1h,6h,12h,1d,7d,14d,30d",
                "current": {"text": "auto", "value": "$__auto_interval_interval"},
            },
        ]
    }

    with open(dst, "w", encoding="utf-8") as f:
        json.dump(dash, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
