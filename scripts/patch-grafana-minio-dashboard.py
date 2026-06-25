#!/usr/bin/env python3
"""Adapte le dashboard MinIO Prometheus (Grafana #25202 / équivalent #20826 InfluxDB)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
MINIO_JOB = "minio"


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
    # Job fixe — évite variable scrape_jobs vide quand Prometheus ne scrape pas encore.
    expr = expr.replace('job=~"$scrape_jobs"', f'job="{MINIO_JOB}"')
    expr = re.sub(
        r'job=~\s*"\$scrape_jobs"',
        f'job="{MINIO_JOB}"',
        expr,
    )
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
        "id": 9200,
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
                "expr": f'up{{job="{MINIO_JOB}", instance="wise-eat-minio:9000"}}',
                "legendFormat": "Prometheus scrape minio",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f'minio_cluster_health_status{{job="{MINIO_JOB}"}}',
                "legendFormat": "cluster health",
                "refId": "B",
            },
        ],
        "title": "MinIO — scrape Prometheus / santé cluster",
        "type": "stat",
    }


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <src.json> <dst.json>", file=sys.stderr)
        sys.exit(1)

    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dash = json.loads(src.read_text(encoding="utf-8"))

    dash["id"] = None
    dash["uid"] = "wise-eat-minio-20826"
    dash["title"] = "Wise Eat — MinIO Storage"
    dash["description"] = (
        "Métriques cluster MinIO (Prometheus). Équivalent du dashboard Grafana #20826 "
        "(InfluxDB 2.0) — job Prometheus : minio — scrape "
        "/minio/v2/metrics/cluster + /minio/v2/metrics/node."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", PROM_UID)
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_dashboard(dash)

    panels = dash.get("panels", [])
    bump_grid_y(panels, 4)
    panels.insert(0, health_panel())
    dash["panels"] = panels

    dash["templating"] = {
        "list": [
            {
                "name": "scrape_jobs",
                "label": "Prometheus job",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{job="{MINIO_JOB}"}}, job)',
                "query": {
                    "query": f'label_values(up{{job="{MINIO_JOB}"}}, job)',
                    "refId": "StandardVariableQuery",
                },
                "refresh": 1,
                "includeAll": False,
                "multi": False,
                "hide": 0,
                "current": {"selected": True, "text": MINIO_JOB, "value": MINIO_JOB},
                "options": [
                    {"selected": True, "text": MINIO_JOB, "value": MINIO_JOB},
                ],
            }
        ]
    }

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
