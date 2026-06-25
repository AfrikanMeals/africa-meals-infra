#!/usr/bin/env python3
"""Adapte le dashboard Grafana Docker #4271 pour Wise Eat (cAdvisor + node_exporter)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
SERVER_HOST = "wise-eat"
NODE_INSTANCE = "wise-eat:9100"
CADVISOR_INSTANCE = "wise-eat:8080"
INSTANCE_PATTERN = f"{SERVER_HOST}:(9100|8080)"

METRIC_RENAMES = [
    ("node_network_transmit_bytes", "node_network_transmit_bytes_total"),
    ("node_network_receive_bytes", "node_network_receive_bytes_total"),
    ("node_disk_bytes_written", "node_disk_written_bytes_total"),
    ("node_disk_bytes_read", "node_disk_read_bytes_total"),
    ("node_filesystem_size", "node_filesystem_size_bytes"),
    ("node_filesystem_free", "node_filesystem_free_bytes"),
    ("node_memory_SwapTotal", "node_memory_SwapTotal_bytes"),
    ("node_memory_SwapFree", "node_memory_SwapFree_bytes"),
    ("node_memory_MemAvailable", "node_memory_MemAvailable_bytes"),
    ("node_memory_MemTotal", "node_memory_MemTotal_bytes"),
    ("node_boot_time", "node_boot_time_seconds"),
    ("node_cpu", "node_cpu_seconds_total"),
]


def fix_ds(obj) -> None:
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if ds in ("Prometheus", "${DS_PROMETHEUS}", "${ds_prometheus}", "-- Grafana --"):
            if ds != "-- Grafana --":
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
    for old, new in METRIC_RENAMES:
        expr = expr.replace(old, new)
    expr = expr.replace(
        "container_label_namespace",
        "container_label_com_docker_compose_project",
    )
    expr = re.sub(
        r'instance=~\s*["\']\$server:\.\*["\']',
        f'instance=~"{INSTANCE_PATTERN}"',
        expr,
    )
    # Namespace vide → tous les projets Compose
    expr = expr.replace(
        'container_label_com_docker_compose_project=~"$namespace"',
        'container_label_com_docker_compose_project=~".+"',
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
        nested = panel.get("panels")
        if isinstance(nested, list):
            bump_grid_y(nested, delta)
        # Ancien schema #4271 (rows sans gridPos sur enfants)
        if panel.get("type") == "row" and nested:
            for child in nested:
                if isinstance(child.get("gridPos"), dict) and "y" in child["gridPos"]:
                    child["gridPos"]["y"] = int(child["gridPos"]["y"]) + delta


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
        "id": 9300,
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
                "expr": f'up{{job="cadvisor", instance="{CADVISOR_INSTANCE}"}}',
                "legendFormat": "cAdvisor",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f'up{{job="node", instance="{NODE_INSTANCE}"}}',
                "legendFormat": "node_exporter",
                "refId": "B",
            },
            {
                "datasource": DS,
                "expr": (
                    f'count(container_last_seen{{instance="{CADVISOR_INSTANCE}",'
                    f'container_label_com_docker_compose_project=~".+"}})'
                ),
                "legendFormat": "conteneurs vus",
                "refId": "C",
            },
        ],
        "title": "Docker — cAdvisor / node_exporter (Wise Eat VPS)",
        "type": "stat",
    }


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <src.json> <dst.json>", file=sys.stderr)
        sys.exit(1)

    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dash = json.loads(src.read_text(encoding="utf-8"))

    dash["id"] = None
    dash["uid"] = "wise-eat-docker-4271"
    dash["title"] = "Wise Eat — Docker Monitoring"
    dash["description"] = (
        "Conteneurs Docker (cAdvisor) + hôte (node_exporter). "
        f"Instances Prometheus : {NODE_INSTANCE} / {CADVISOR_INSTANCE}."
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
                "name": "server",
                "label": "Node",
                "type": "query",
                "datasource": DS,
                "query": 'label_values(node_uname_info{job="node"}, instance)',
                "definition": 'label_values(node_uname_info{job="node"}, instance)',
                "regex": "/([^:]+):.*/",
                "refresh": 1,
                "includeAll": False,
                "multi": False,
                "hide": 0,
                "current": {
                    "selected": True,
                    "text": SERVER_HOST,
                    "value": SERVER_HOST,
                },
                "options": [
                    {"selected": True, "text": SERVER_HOST, "value": SERVER_HOST},
                ],
            },
            {
                "name": "namespace",
                "label": "Compose project",
                "type": "query",
                "datasource": DS,
                "query": "label_values(container_label_com_docker_compose_project)",
                "definition": "label_values(container_label_com_docker_compose_project)",
                "refresh": 1,
                "includeAll": True,
                "allValue": ".+",
                "multi": True,
                "hide": 0,
                "current": {"selected": True, "text": "All", "value": "$__all"},
                "options": [],
            },
        ]
    }

    # Le dashboard #4271 embarque une fenêtre figée en 2018 → toujours « No data ».
    dash["time"] = {"from": "now-24h", "to": "now"}
    dash["timepicker"] = dash.get("timepicker") or {}
    dash["timepicker"]["refresh_intervals"] = dash["timepicker"].get(
        "refresh_intervals",
        ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h", "2h", "1d"],
    )

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
