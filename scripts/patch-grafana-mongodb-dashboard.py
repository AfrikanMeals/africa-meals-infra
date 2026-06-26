#!/usr/bin/env python3
"""Patch dashboard Grafana MongoDB (Percona exporter) pour Wise Eat."""
import json
import sys

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}


def fix_ds(obj):
    if isinstance(obj, dict):
        if obj.get("datasource") in ("Prometheus", "${DS_PROMETHEUS}", "${DS_PROM}"):
            obj["datasource"] = DS
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)


def main():
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

    dash["templating"] = {
        "list": [
            {
                "name": "instance",
                "type": "query",
                "datasource": DS,
                "definition": "label_values(mongodb_up, instance)",
                "query": "label_values(mongodb_up, instance)",
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "hide": 0,
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
        ]
    }

    with open(dst, "w", encoding="utf-8") as f:
        json.dump(dash, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
