#!/usr/bin/env python3
"""Adapte le dashboard Grafana #4271 (métriques legacy + labels Docker Compose)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}

# Anciens noms (dashboard 4271) → node_exporter / cAdvisor actuels.
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
    for old, new in METRIC_RENAMES:
        expr = expr.replace(old, new)
    expr = expr.replace(
        "container_label_namespace",
        "container_label_com_docker_compose_project",
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
        "Job Prometheus : node + cadvisor — instance wise-eat:9100 / wise-eat:8080."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", PROM_UID)
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_dashboard(dash)

    for var in dash.get("templating", {}).get("list", []):
        if var.get("name") == "namespace":
            var["label"] = "Compose project"
            var["query"] = "label_values(container_label_com_docker_compose_project)"
        if var.get("name") == "server":
            var["query"] = "label_values(node_boot_time_seconds, instance)"
        if var.get("datasource"):
            var["datasource"] = DS

    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
