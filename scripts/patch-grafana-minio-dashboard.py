#!/usr/bin/env python3
"""Adapte le dashboard MinIO Prometheus (Grafana #25202 / équivalent #20826 InfluxDB)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
# Jobs Prometheus (minio-cluster + minio-node ; « minio » = rétrocompat relabel)
MINIO_JOBS = "minio-cluster|minio-node|minio"
MINIO_JOB_FILTER = f'job=~"{MINIO_JOBS}"'

# Panneaux jauge affichés en stat (timeseries trop petits → « No data » Grafana 10)
GAUGE_STAT_TITLES = frozenset(
    {
        "Open FDs ",
        "Goroutines",
        "Open FDs",
    }
)


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
    expr = expr.replace('job=~"$scrape_jobs"', MINIO_JOB_FILTER)
    expr = re.sub(r'job=~\s*"\$scrape_jobs"', MINIO_JOB_FILTER, expr)
    expr = re.sub(r'job="minio"', MINIO_JOB_FILTER, expr)

    # Capacity : agrégation cluster (label server), pas topk/sum by instance
    expr = re.sub(
        r"topk\(1, sum\(minio_cluster_capacity_usable_total_bytes\{([^}]+)\}\)"
        r" by \(instance\)\)\s*-\s*topk\(1, sum\(minio_cluster_capacity_usable_free_bytes\{([^}]+)\}\)"
        r" by \(instance\)\)",
        r"max(minio_cluster_capacity_usable_total_bytes{\1})"
        r" - max(minio_cluster_capacity_usable_free_bytes{\2})",
        expr,
    )
    expr = re.sub(
        r"topk\(1, sum\(minio_cluster_capacity_usable_free_bytes\{([^}]+)\}\)"
        r" by \(instance\)\)\s*",
        r"max(minio_cluster_capacity_usable_free_bytes{\1})",
        expr,
    )

    # S3 traffic (compteurs cluster) — max plus fiable que sum by (instance)
    if "minio_s3_traffic_received_bytes" in expr or "minio_s3_traffic_sent_bytes" in expr:
        expr = re.sub(
            r"sum by \(instance\) \(",
            "max(",
            expr,
            count=1,
        )

    # Jauges node : max() si requête nue (une série par server)
    for metric in (
        "minio_node_file_descriptor_open_total",
        "minio_node_go_routine_total",
    ):
        m = re.fullmatch(rf"{metric}\{{(.+)\}}", expr.strip())
        if m and not expr.strip().startswith("max("):
            expr = f"max({metric}{{{m.group(1)}}})"
            break

    return expr


def patch_target(target: dict, *, panel_type: str, panel_title: str) -> None:
    if "expr" in target and isinstance(target["expr"], str):
        target["expr"] = patch_expr(target["expr"])

    if panel_type == "stat" or panel_title in GAUGE_STAT_TITLES:
        target["instant"] = True
        target["format"] = "time_series"
        if panel_type == "timeseries" and panel_title in GAUGE_STAT_TITLES:
            target.pop("intervalFactor", None)
            target.pop("step", None)

    if panel_type == "piechart":
        target["instant"] = True
        target["format"] = "time_series"


def patch_panels(panels: list) -> None:
    for panel in panels:
        ptype = panel.get("type", "")
        title = panel.get("title", "")
        for target in panel.get("targets") or []:
            if isinstance(target, dict):
                patch_target(target, panel_type=ptype, panel_title=title)

        if title in GAUGE_STAT_TITLES and ptype == "timeseries":
            panel["type"] = "stat"
            opts = panel.setdefault("options", {})
            opts.setdefault("reduceOptions", {})
            opts["reduceOptions"].setdefault("calcs", ["lastNotNull"])
            opts.setdefault("colorMode", "value")
            opts.setdefault("graphMode", "none")
            opts.setdefault("textMode", "auto")

        if ptype == "row" and panel.get("panels"):
            patch_panels(panel["panels"])


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
                "expr": f'min(up{{{MINIO_JOB_FILTER}, instance="wise-eat-minio:9000"}})',
                "instant": True,
                "format": "time_series",
                "legendFormat": "Prometheus scrape minio",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f"max(minio_cluster_health_status{{{MINIO_JOB_FILTER}}})",
                "instant": True,
                "format": "time_series",
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
        "Métriques MinIO (Prometheus). Jobs : minio-cluster + minio-node. "
        "Capacité / objets : remplis après le premier scan MinIO (quelques minutes). "
        "KMS : N/A si chiffrement KMS désactivé."
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
                "name": "scrape_jobs",
                "label": "Prometheus job",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{{MINIO_JOB_FILTER}}}, job)',
                "query": {
                    "query": f'label_values(up{{{MINIO_JOB_FILTER}}}, job)',
                    "refId": "StandardVariableQuery",
                },
                "refresh": 1,
                "includeAll": True,
                "multi": True,
                "hide": 0,
                "regex": "",
                "current": {"selected": True, "text": "All", "value": "$__all"},
            }
        ]
    }

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
