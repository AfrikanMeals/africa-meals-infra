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

    # Dashboard #12079 filtre par instance=~"$env" — conserver la variable env.
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

    # Panneaux disque : lier au node_exporter VPS (toutes les occurrences).
    if "node_disk_" in expr:
        expr = re.sub(
            r"(node_disk_[a-z_]+)(?!\{)",
            rf'\1{{instance="{NODE_INSTANCE}",job="node"}}',
            expr,
        )

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

    # Variable env (dashboard #12079) — NE PAS renommer en instance ($env dans les requêtes).
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
