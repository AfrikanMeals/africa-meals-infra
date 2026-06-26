#!/usr/bin/env python3
"""Adapte le dashboard MongoDB #18847 (Percona exporter ss/sys) pour Wise Eat."""
from __future__ import annotations

import json
import re
import sys

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
MONGO_JOB = "mongodb"
NODE_INSTANCE = "wise-eat:9100"


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


def patch_expr(expr: str) -> str:
    if not expr:
        return expr

    expr = expr.replace("nmongodb_sys_", "mongodb_sys_")

    if "node_load1" in expr:
        expr = re.sub(
            r'node_load1\{instance=~"\$instance"\}',
            f'node_load1{{job="node",instance="{NODE_INSTANCE}"}}',
            expr,
        )

    if "mongodb_" not in expr:
        return expr

    if "job=" in expr:
        return expr

    if 'instance=~"$instance"' in expr:
        return re.sub(
            r'\{instance=~"\$instance"',
            f'{{job="{MONGO_JOB}",instance=~"$instance"',
            expr,
        )

    if re.search(r"mongodb_\w+\{", expr):
        expr = re.sub(
            r"(mongodb_\w+)\{",
            rf'\1{{job="{MONGO_JOB}",',
            expr,
            count=1,
        )
        if 'instance=~' not in expr:
            expr = re.sub(
                rf'\{{job="{MONGO_JOB}",',
                f'{{job="{MONGO_JOB}",instance=~"$instance",',
                expr,
                count=1,
            )
        return expr

    return re.sub(
        r"(mongodb_\w+)([\[\{])",
        rf'\1{{job="{MONGO_JOB}",instance=~"$instance"}}\2',
        expr,
        count=1,
    )


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


def migrate_graph(panel: dict) -> None:
    if panel.get("type") != "graph":
        return
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


def migrate_panels(panels: list) -> None:
    for panel in panels:
        migrate_graph(panel)
        patch_targets(panel)
        nested = panel.get("panels")
        if isinstance(nested, list):
            migrate_panels(nested)


def patch_dashboard(obj) -> None:
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            obj["expr"] = patch_expr(obj["expr"])
        q = obj.get("query")
        if isinstance(q, str):
            obj["query"] = patch_expr(q)
        elif isinstance(q, dict) and isinstance(q.get("query"), str):
            q["query"] = patch_expr(q["query"])
        for v in obj.values():
            patch_dashboard(v)
    elif isinstance(obj, list):
        for item in obj:
            patch_dashboard(item)


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        dash = json.load(f)

    dash["id"] = None
    dash["uid"] = "wise-eat-mongodb-18847"
    dash["title"] = "Wise Eat — MongoDB Overview"
    dash["description"] = (
        "MongoDB Percona exporter (métriques ss/sys). "
        "Base Grafana.com #18847 — job=mongodb, instance=wise-eat-mongo-1:27017."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", "Prometheus")
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_dashboard(dash)
    migrate_panels(dash.get("panels") or [])

    dash["templating"] = {
        "list": [
            {
                "name": "instance",
                "label": "instance",
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
