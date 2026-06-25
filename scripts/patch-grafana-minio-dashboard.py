#!/usr/bin/env python3
"""Adapte le dashboard MinIO Prometheus (Grafana #25202 / équivalent #20826 InfluxDB)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}


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
        "(InfluxDB 2.0) — job Prometheus : minio — scrape /minio/v2/metrics/cluster."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", PROM_UID)
    repl = repl.replace("${DS_PROM}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)

    for var in dash.get("templating", {}).get("list", []):
        if var.get("name") == "scrape_jobs":
            var["label"] = "Prometheus job"
            var["definition"] = "label_values(minio_cluster_health_status, job)"
            var["query"] = {
                "query": "label_values(minio_cluster_health_status, job)",
                "refId": "StandardVariableQuery",
            }
            var["current"] = {"selected": True, "text": "minio", "value": "minio"}
        if var.get("datasource"):
            var["datasource"] = DS

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
