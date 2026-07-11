#!/usr/bin/env python3
"""Adapte le dashboard PapaDanielVi/neo4j-exporter pour Wise Eat (job=neo4j)."""
from __future__ import annotations

import json
import sys

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
NEO4J_JOB = "neo4j"


def walk(obj, fn):
    if isinstance(obj, dict):
        fn(obj)
        for v in obj.values():
            walk(v, fn)
    elif isinstance(obj, list):
        for item in obj:
            walk(item, fn)


def fix_datasource(node: dict) -> None:
    ds = node.get("datasource")
    if ds == "${datasource}" or ds == "Prometheus":
        node["datasource"] = DS
    elif isinstance(ds, dict) and (
        ds.get("uid") == "${datasource}" or ds.get("type") == "prometheus"
    ):
        node["datasource"] = DS


def fix_expr(node: dict) -> None:
    expr = node.get("expr")
    if not isinstance(expr, str):
        return
    # Dashboard upstream filtre sur label `target` (proxy mode) — standalone = job.
    expr = expr.replace('target=~"$target"', f'job=~"$job"')
    expr = expr.replace('target="$target"', f'job=~"$job"')
    if "neo4j_" in expr and "job=" not in expr:
        if "{" in expr:
            expr = expr.replace("{", f'{{job=~"$job",', 1)
        else:
            expr = f'{expr}{{job=~"$job"}}'
    node["expr"] = expr


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        dash = json.load(f)

    walk(dash, fix_datasource)
    walk(dash, fix_expr)

    dash["id"] = None
    dash["uid"] = "wise-eat-neo4j-exporter"
    dash["title"] = "Wise Eat — Neo4j"
    dash["tags"] = ["neo4j", "wise-eat", "graphdb"]
    dash["description"] = (
        "Neo4j Community via PapaDanielVi/neo4j-exporter (Bolt). "
        "job=neo4j · instance=wise-eat-neo4j:7687 · scrape :9217. "
        "Métriques APOC store/tx optionnelles si plugins APOC installés."
    )

    # Panneaux cAdvisor (conteneur wise-eat-neo4j) — always utiles même si Bolt down.
    y_max = 0
    for p in dash.get("panels", []):
        gp = p.get("gridPos") or {}
        y_max = max(y_max, int(gp.get("y", 0)) + int(gp.get("h", 0)))

    cadvisor_row = {
        "title": "Docker container (cAdvisor)",
        "type": "row",
        "collapsed": False,
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y_max},
        "panels": [],
    }
    mem_panel = {
        "title": "Container memory (wise-eat-neo4j)",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": y_max + 1},
        "datasource": DS,
        "targets": [
            {
                "expr": (
                    'container_memory_working_set_bytes{job="cadvisor",'
                    'name="wise-eat-neo4j"}'
                ),
                "legendFormat": "working set",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "unit": "bytes",
                "custom": {
                    "drawStyle": "line",
                    "lineInterpolation": "linear",
                    "fillOpacity": 15,
                },
            }
        },
    }
    cpu_panel = {
        "title": "Container CPU (wise-eat-neo4j)",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": y_max + 1},
        "datasource": DS,
        "targets": [
            {
                "expr": (
                    'rate(container_cpu_usage_seconds_total{job="cadvisor",'
                    'name="wise-eat-neo4j"}[5m])'
                ),
                "legendFormat": "cores",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "unit": "short",
                "custom": {
                    "drawStyle": "line",
                    "lineInterpolation": "linear",
                    "fillOpacity": 15,
                },
            }
        },
    }
    dash.setdefault("panels", []).extend([cadvisor_row, mem_panel, cpu_panel])

    dash["templating"] = {
        "list": [
            {
                "name": "job",
                "type": "query",
                "label": "Job",
                "datasource": DS,
                "definition": f'label_values(neo4j_exporter_up{{job="{NEO4J_JOB}"}}, job)',
                "query": f'label_values(neo4j_exporter_up{{job="{NEO4J_JOB}"}}, job)',
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "hide": 0,
                "current": {
                    "selected": True,
                    "text": NEO4J_JOB,
                    "value": NEO4J_JOB,
                },
            }
        ]
    }

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    with open(dst, "w", encoding="utf-8") as f:
        json.dump(dash, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
