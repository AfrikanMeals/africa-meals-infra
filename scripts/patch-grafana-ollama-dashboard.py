#!/usr/bin/env python3
"""Adapte le dashboard Grafana #25086 (Ollama LLM Inference) pour Wise Eat."""
from __future__ import annotations

import json
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
JOB = 'job="ollama"'
IDLE = f' or on() (0 * ollama_up{{{JOB}}})'

# Fallbacks : sans modèle en VRAM ni requête proxy, l'exporter ne publie que ollama_up.
EXPR_PATCHES = {
    "ollama_up": f'ollama_up{{{JOB}}}',
    f"ollama_model_loaded{{{JOB}}}": f'max(ollama_model_loaded{{{JOB}}}) or on() vector(0)',
    f"ollama_model_vram_bytes{{{JOB}}}": f'sum(ollama_model_vram_bytes{{{JOB}}}) or on() vector(0)',
    f"ollama_tokens_per_second{{{JOB}}}": f'sum(ollama_tokens_per_second{{{JOB}}}) or on() vector(0)',
    f"ollama_prompt_tokens_per_second{{{JOB}}}": f'sum(ollama_prompt_tokens_per_second{{{JOB}}}) or on() vector(0)',
    f'increase(ollama_requests_total{{{JOB}}}[24h])': (
        f'sum(increase(ollama_requests_total{{{JOB}}}[24h])) or on() vector(0)'
    ),
    f'histogram_quantile(0.50, rate(ollama_request_duration_seconds_bucket{{{JOB}}},endpoint=~"$endpoint"[5m]))': (
        f'(histogram_quantile(0.50, rate(ollama_request_duration_seconds_bucket{{{JOB}}},endpoint=~"$endpoint"[5m])){IDLE})'
    ),
    f'histogram_quantile(0.95, rate(ollama_request_duration_seconds_bucket{{{JOB}}},endpoint=~"$endpoint"[5m]))': (
        f'(histogram_quantile(0.95, rate(ollama_request_duration_seconds_bucket{{{JOB}}},endpoint=~"$endpoint"[5m])){IDLE})'
    ),
    f'histogram_quantile(0.99, rate(ollama_request_duration_seconds_bucket{{{JOB}}},endpoint=~"$endpoint"[5m]))': (
        f'(histogram_quantile(0.99, rate(ollama_request_duration_seconds_bucket{{{JOB}}},endpoint=~"$endpoint"[5m])){IDLE})'
    ),
    f'histogram_quantile(0.95, rate(ollama_eval_duration_seconds_bucket{{{JOB}}}[5m]))': (
        f'(histogram_quantile(0.95, rate(ollama_eval_duration_seconds_bucket{{{JOB}}}[5m])){IDLE})'
    ),
    f'histogram_quantile(0.95, rate(ollama_prompt_eval_duration_seconds_bucket{{{JOB}}}[5m]))': (
        f'(histogram_quantile(0.95, rate(ollama_prompt_eval_duration_seconds_bucket{{{JOB}}}[5m])){IDLE})'
    ),
    f"ollama_kv_cache_pressure_ratio{{{JOB}}}": f'(ollama_kv_cache_pressure_ratio{{{JOB}}}{IDLE})',
    f'increase(ollama_model_load_total{{{JOB}}}[5m])': f'(increase(ollama_model_load_total{{{JOB}}}[5m]){IDLE})',
    f'increase(ollama_model_unload_total{{{JOB}}}[5m])': f'(increase(ollama_model_unload_total{{{JOB}}}[5m]){IDLE})',
    f'ollama_requests_in_flight{{{JOB}}},endpoint=~"$endpoint"': (
        f'(ollama_requests_in_flight{{{JOB}}},endpoint=~"$endpoint"{IDLE})'
    ),
    f'rate(ollama_requests_total{{{JOB}}},endpoint=~"$endpoint"[5m])': (
        f'(sum(rate(ollama_requests_total{{{JOB}}},endpoint=~"$endpoint"[5m])){IDLE})'
    ),
}


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


def patch_exprs(obj) -> None:
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            obj["expr"] = EXPR_PATCHES.get(obj["expr"], obj["expr"])
        for v in obj.values():
            patch_exprs(v)
    elif isinstance(obj, list):
        for item in obj:
            patch_exprs(item)


def reference_panel() -> dict:
    return {
        "id": 99,
        "title": "Référence Wise Eat",
        "type": "text",
        "gridPos": {"h": 5, "w": 24, "x": 0, "y": 25},
        "options": {
            "mode": "markdown",
            "content": (
                "## Wise Eat — Ollama\n\n"
                "- **Modèles** : `nomic-embed-text`, `llama3.2:3b`\n"
                "- **API directe** : `http://127.0.0.1:11434`\n"
                "- **Proxy métriques** : `http://127.0.0.1:9401` → TPS, latences, requêtes\n"
                "- **Exporter** : `http://127.0.0.1:9400/metrics` (`job=ollama`)\n\n"
                "**0 partout** (pas « No data ») = Ollama UP mais aucune requête via le proxy `:9401` "
                "et aucun modèle en VRAM.\n\n"
                "Charger un modèle : `curl -s http://127.0.0.1:11434/api/generate "
                "-d '{\"model\":\"llama3.2:3b\",\"prompt\":\"ping\",\"stream\":false}'`\n\n"
                "Métriques requêtes : `OLLAMA_BASE_URL=http://127.0.0.1:9401` (africa-meals-api sur le VPS)."
            ),
        },
    }


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
    dash["description"] = (
        "Grafana #25086 + ollama-exporter (maravexa). "
        "Poller : VRAM/modèle. Proxy :9401 : TPS/latences/requêtes."
    )

    repl = json.dumps(dash)
    repl = repl.replace("${DS_PROMETHEUS}", PROM_UID)
    repl = repl.replace("${datasource}", PROM_UID)
    dash = json.loads(repl)

    for key in ("__inputs", "__requires", "__elements"):
        dash.pop(key, None)

    fix_ds(dash)
    patch_exprs(dash)

    dash["templating"] = {
        "list": [
            {
                "name": "endpoint",
                "label": "Endpoint",
                "type": "query",
                "datasource": DS,
                "query": f'label_values(ollama_requests_total{{{JOB}}}, endpoint)',
                "definition": f'label_values(ollama_requests_total{{{JOB}}}, endpoint)',
                "refresh": 2,
                "multi": True,
                "includeAll": True,
                "allValue": ".+",
                "hide": 0,
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
        ]
    }

    panels = dash.get("panels", [])
    if not any(p.get("id") == 99 for p in panels):
        panels.append(reference_panel())
    dash["panels"] = panels

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {dst}")


if __name__ == "__main__":
    main()
