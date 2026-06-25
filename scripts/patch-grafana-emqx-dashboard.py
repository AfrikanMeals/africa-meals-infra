#!/usr/bin/env python3
"""Adapte le dashboard EMQX 5 (Grafana.com #17446) pour Wise Eat / Prometheus."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
EMQX_JOB = "emqx"


def fix_ds(obj) -> None:
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if ds in ("Prometheus", "${DS_PROMETHEUS}", "${ds_prometheus}"):
            obj["datasource"] = DS
        elif isinstance(ds, dict) and ds.get("type") == "prometheus":
            obj["datasource"] = DS
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)


def patch_expr(expr: str) -> str:
    expr = expr.replace('job="emqx"', f'job="{EMQX_JOB}"')
    expr = re.sub(
        r'instance=~"\.?"\*?"',
        'instance=~"$instance"',
        expr,
    )
    expr = expr.replace('instance=~".*"', 'instance=~"$instance"')
    return expr


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
    with Path(src).open(encoding="utf-8") as f:
        dash = json.load(f)

    dash["id"] = None
    dash["uid"] = "wise-eat-emqx-17446"
    dash["title"] = "Wise Eat — EMQX"
    dash["description"] = (
        "Broker MQTT EMQX 5 (cluster 1 primary + 2 réplicas). "
        "Scrape Prometheus job=emqx → /api/v5/prometheus/stats."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", "Prometheus")
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_panel_exprs(dash)

    health_panel = {
        "datasource": DS,
        "fieldConfig": {
            "defaults": {
                "mappings": [
                    {
                        "options": {"0": {"text": "DOWN", "color": "red"}},
                        "type": "value",
                    },
                    {
                        "options": {"1": {"text": "UP", "color": "green"}},
                        "type": "value",
                    },
                ],
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "red", "value": None},
                        {"color": "green", "value": 1},
                    ],
                },
            },
            "overrides": [],
        },
        "gridPos": {"h": 4, "w": 24, "x": 0, "y": 0},
        "id": 9400,
        "options": {
            "colorMode": "background",
            "graphMode": "none",
            "justifyMode": "auto",
            "orientation": "horizontal",
            "reduceOptions": {
                "calcs": ["lastNotNull"],
                "fields": "",
                "values": False,
            },
            "textMode": "value_and_name",
        },
        "pluginVersion": "10.3.3",
        "targets": [
            {
                "datasource": DS,
                "expr": f'max(up{{job="{EMQX_JOB}"}}) or vector(0)',
                "instant": True,
                "legendFormat": "Prometheus scrape EMQX",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f'count(up{{job="{EMQX_JOB}"}} == 1)',
                "instant": True,
                "legendFormat": "Nœuds scrapés",
                "refId": "B",
            },
            {
                "datasource": DS,
                "expr": f'max(emqx_cluster_nodes_running{{job="{EMQX_JOB}"}})',
                "instant": True,
                "legendFormat": "Nœuds cluster actifs",
                "refId": "C",
            },
        ],
        "title": "EMQX — scrape & cluster",
        "type": "stat",
    }

    panels = dash.get("panels", [])
    for p in panels:
        gp = p.get("gridPos") or {}
        if isinstance(gp.get("y"), (int, float)):
            gp["y"] = gp["y"] + 4
    dash["panels"] = [health_panel] + panels

    dash["templating"] = {
        "list": [
            {
                "name": "instance",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{job="{EMQX_JOB}"}}, instance)',
                "query": f'label_values(up{{job="{EMQX_JOB}"}}, instance)',
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "hide": 0,
                "allValue": ".*",
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
        ]
    }

    with Path(dst).open("w", encoding="utf-8") as f:
        json.dump(dash, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
