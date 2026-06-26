#!/usr/bin/env python3
"""Adapte le dashboard Grafana #25086 (Ollama LLM Inference) pour Wise Eat."""
from __future__ import annotations

import json
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}


def fix_ds(obj) -> None:
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if ds in ("Prometheus", "prometheus", "${DS_PROMETHEUS}", "${datasource}"):
            obj["datasource"] = DS
        elif isinstance(ds, dict) and ds.get("uid") in ("${ds_prometheus}", "Prometheus", PROM_UID):
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
    dash["uid"] = "wise-eat-ollama-25086"
    dash["title"] = "Wise Eat — Ollama LLM Inference"
    dash["tags"] = ["wise-eat", "ollama", "llm", "inference", "ai"]

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", PROM_UID)
    repl = repl.replace("${datasource}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)

    dash["templating"] = {
        "list": [
            {
                "name": "endpoint",
                "label": "Endpoint",
                "type": "query",
                "datasource": DS,
                "query": 'label_values(ollama_requests_total{job="ollama"}, endpoint)',
                "definition": 'label_values(ollama_requests_total{job="ollama"}, endpoint)',
                "refresh": 2,
                "multi": True,
                "includeAll": True,
                "allValue": ".+",
                "hide": 0,
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
        ]
    }

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
