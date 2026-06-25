#!/usr/bin/env python3
"""Adapte le dashboard Grafana Node Exporter #1860 pour Wise Eat (job node, instance fixe)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
NODE_JOB = "node"
NODE_INSTANCE = "wise-eat:9100"


def fix_ds(obj) -> None:
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if ds in ("Prometheus", "${DS_PROMETHEUS}", "${ds_prometheus}"):
            obj["datasource"] = DS
        elif isinstance(ds, dict) and ds.get("uid") in (
            "${ds_prometheus}",
            "Prometheus",
            PROM_UID,
        ):
            obj["datasource"] = DS
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)


def patch_expr(expr: str) -> str:
    expr = expr.replace('job="$job"', f'job="{NODE_JOB}"')
    expr = expr.replace('instance="$node"', f'instance="{NODE_INSTANCE}"')
    return expr


def patch_dashboard(obj) -> None:
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            obj["expr"] = patch_expr(obj["expr"])
        if "query" in obj and isinstance(obj["query"], str):
            obj["query"] = patch_expr(obj["query"])
        for v in obj.values():
            patch_dashboard(v)
    elif isinstance(obj, list):
        for item in obj:
            patch_dashboard(item)


def bump_grid_y(panels: list, delta: int) -> None:
    for panel in panels:
        grid = panel.get("gridPos")
        if isinstance(grid, dict) and "y" in grid:
            grid["y"] = int(grid["y"]) + delta
        if panel.get("type") == "row" and panel.get("panels"):
            bump_grid_y(panel["panels"], delta)


def health_panel() -> dict:
    return {
        "datasource": DS,
        "fieldConfig": {
            "defaults": {
                "mappings": [
                    {"options": {"0": {"text": "DOWN", "color": "red"}}, "type": "value"},
                    {"options": {"1": {"text": "UP", "color": "green"}}, "type": "value"},
                ],
                "thresholds": {
                    "mode": "absolute",
                    "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}],
                },
            },
            "overrides": [],
        },
        "gridPos": {"h": 4, "w": 24, "x": 0, "y": 0},
        "id": 9100,
        "options": {
            "colorMode": "background",
            "graphMode": "none",
            "justifyMode": "auto",
            "orientation": "horizontal",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "textMode": "value_and_name",
        },
        "pluginVersion": "10.3.3",
        "targets": [
            {
                "datasource": DS,
                "expr": f'up{{job="{NODE_JOB}", instance="{NODE_INSTANCE}"}}',
                "legendFormat": "node_exporter scrape",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f'node_uname_info{{job="{NODE_JOB}", instance="{NODE_INSTANCE}"}}',
                "legendFormat": "{{nodename}} {{machine}}",
                "refId": "B",
            },
        ],
        "title": "Node Exporter — scrape Prometheus / hôte VPS",
        "type": "stat",
    }


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <src.json> <dst.json>", file=sys.stderr)
        sys.exit(1)

    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dash = json.loads(src.read_text(encoding="utf-8"))

    dash["id"] = None
    dash["uid"] = "wise-eat-node-1860"
    dash["title"] = "Wise Eat — System (Node Exporter)"
    dash["description"] = (
        f"Métriques hôte VPS via node_exporter. Job Prometheus : {NODE_JOB} — "
        f"instance {NODE_INSTANCE} (:9100)."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${ds_prometheus}", PROM_UID)
    repl = repl.replace('"uid": "${ds_prometheus}"', f'"uid": "{PROM_UID}"')
    repl = repl.replace("${DS_PROMETHEUS}", PROM_UID)
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_dashboard(dash)

    templating = dash.get("templating", {}).get("list", [])
    dash["templating"]["list"] = [
        v for v in templating if v.get("name") != "ds_prometheus"
    ]
    for var in dash["templating"]["list"]:
        if var.get("datasource"):
            var["datasource"] = DS

    panels = dash.get("panels", [])
    bump_grid_y(panels, 4)
    panels.insert(0, health_panel())
    dash["panels"] = panels

    dash["templating"] = {
        "list": [
            {
                "name": "job",
                "label": "Job",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{job="{NODE_JOB}"}}, job)',
                "query": {
                    "query": f'label_values(up{{job="{NODE_JOB}"}}, job)',
                    "refId": "Prometheus-job-Variable-Query",
                },
                "refresh": 1,
                "includeAll": False,
                "hide": 0,
                "current": {"selected": True, "text": NODE_JOB, "value": NODE_JOB},
                "options": [{"selected": True, "text": NODE_JOB, "value": NODE_JOB}],
            },
            {
                "name": "nodename",
                "label": "Nodename",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(node_uname_info{{job="{NODE_JOB}"}}, nodename)',
                "query": {
                    "query": f'label_values(node_uname_info{{job="{NODE_JOB}"}}, nodename)',
                    "refId": "Prometheus-nodename-Variable-Query",
                },
                "refresh": 1,
                "includeAll": False,
                "hide": 0,
                "current": {},
                "options": [],
            },
            {
                "name": "node",
                "label": "Instance",
                "type": "query",
                "datasource": DS,
                "definition": (
                    f'label_values(node_uname_info{{job="{NODE_JOB}"}}, instance)'
                ),
                "query": {
                    "query": (
                        f'label_values(node_uname_info{{job="{NODE_JOB}"}}, instance)'
                    ),
                    "refId": "Prometheus-node-Variable-Query",
                },
                "refresh": 1,
                "includeAll": False,
                "hide": 0,
                "current": {
                    "selected": True,
                    "text": NODE_INSTANCE,
                    "value": NODE_INSTANCE,
                },
                "options": [
                    {"selected": True, "text": NODE_INSTANCE, "value": NODE_INSTANCE},
                ],
            },
        ]
    }

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
