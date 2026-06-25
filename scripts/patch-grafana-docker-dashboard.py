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
INSTANCE_MIXED = "wise-eat:(9100|8080)"
INSTANCE_MIXED_RE = rf'instance=~"{re.escape(INSTANCE_MIXED)}"'

# cAdvisor : name=/wise-eat-redis-cache — plus fiable que compose.project seul
CONTAINER_FILTER = 'name=~".*wise-eat.*"'

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
        if ds in ("Prometheus", "prometheus", "${DS_PROMETHEUS}", "${ds_prometheus}"):
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


def apply_metric_renames(expr: str) -> str:
    """Renomme les métriques legacy #4271 sans double-substitution (node_cpu → …_seconds_total)."""
    for old, new in sorted(METRIC_RENAMES, key=lambda x: -len(x[0])):
        expr = re.sub(rf"\b{re.escape(old)}(?=\{{|,|\s|\)|$)", new, expr)
    return expr


def patch_expr(expr: str) -> str:
    expr = apply_metric_renames(expr)

    expr = expr.replace(
        "container_label_namespace",
        "container_label_com_docker_compose_project",
    )
    expr = re.sub(
        r'instance=~\s*["\']\$server:\.\*["\']',
        f'instance=~"{INSTANCE_MIXED}"',
        expr,
    )

    expr = expr.replace(
        'container_label_com_docker_compose_project=~"$namespace"',
        CONTAINER_FILTER,
    )
    expr = expr.replace(
        'container_label_com_docker_compose_project=~".+"',
        CONTAINER_FILTER,
    )

    if "container_" in expr:
        expr = re.sub(
            INSTANCE_MIXED_RE,
            f'instance="{CADVISOR_INSTANCE}"',
            expr,
        )
    elif "node_" in expr:
        expr = re.sub(
            INSTANCE_MIXED_RE,
            f'instance="{NODE_INSTANCE}"',
            expr,
        )

    return expr


def patch_panel_targets(panel: dict) -> None:
    ptype = panel.get("type", "")
    for target in panel.get("targets") or []:
        if not isinstance(target, dict):
            continue
        if "expr" in target and isinstance(target["expr"], str):
            target["expr"] = patch_expr(target["expr"])
        if ptype in ("stat", "singlestat", "gauge"):
            target["instant"] = True
            target["format"] = "time_series"


def patch_panels(panels: list) -> None:
    for panel in panels:
        patch_panel_targets(panel)
        nested = panel.get("panels")
        if isinstance(nested, list):
            patch_panels(nested)


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


def bump_grid_y(panels: list, delta: int) -> None:
    for panel in panels:
        grid = panel.get("gridPos")
        if isinstance(grid, dict) and "y" in grid:
            grid["y"] = int(grid["y"]) + delta
        nested = panel.get("panels")
        if isinstance(nested, list):
            bump_grid_y(nested, delta)


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
                "instant": True,
                "format": "time_series",
                "legendFormat": "cAdvisor",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f'up{{job="node", instance="{NODE_INSTANCE}"}}',
                "instant": True,
                "format": "time_series",
                "legendFormat": "node_exporter",
                "refId": "B",
            },
            {
                "datasource": DS,
                "expr": (
                    f'count(container_last_seen{{instance="{CADVISOR_INSTANCE}",'
                    f'{CONTAINER_FILTER}}})'
                ),
                "instant": True,
                "format": "time_series",
                "legendFormat": "conteneurs wise-eat",
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
        f"Instances : {NODE_INSTANCE} / {CADVISOR_INSTANCE}."
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
    patch_panels(panels)
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
                "query": (
                    f'label_values(container_label_com_docker_compose_project'
                    f'{{instance="{CADVISOR_INSTANCE}"}}, '
                    f"container_label_com_docker_compose_project)"
                ),
                "definition": (
                    f'label_values(container_label_com_docker_compose_project'
                    f'{{instance="{CADVISOR_INSTANCE}"}}, '
                    f"container_label_com_docker_compose_project)"
                ),
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
