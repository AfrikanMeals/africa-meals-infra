#!/usr/bin/env python3
"""Post-traitement dashboards Wise Eat — primary / réplicas distincts dans Grafana."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_DS = {"type": "prometheus", "uid": "prometheus"}

REDIS_LEGEND = "{{redis_role}} {{redis_instance}}:{{redis_port}}"
MEMCACHED_LEGEND = "{{memcached_role}} :{{memcached_port}}"


def var_query(name: str, definition: str, label: str) -> dict:
    return {
        "name": name,
        "label": label,
        "type": "query",
        "datasource": PROM_DS,
        "definition": definition,
        "query": definition,
        "refresh": 2,
        "includeAll": True,
        "multi": True,
        "hide": 0,
        "current": {"selected": True, "text": "All", "value": "$__all"},
    }


def walk_panels(panels: list, fn) -> None:
    for panel in panels:
        fn(panel)
        if panel.get("type") == "row" and panel.get("panels"):
            walk_panels(panel["panels"], fn)


def patch_redis_expr(expr: str) -> str:
    if "redis_" not in expr and "redis_up" not in expr:
        return expr
    filt = (
        'job=~"$job", redis_role=~"$redis_role", '
        'redis_instance=~"$redis_instance", instance=~"$instance"'
    )
    if '{instance=~"$instance"}' in expr:
        return expr.replace('{instance=~"$instance"}', "{" + filt + "}")
    if "{" in expr and "instance=~" not in expr:
        return re.sub(r"\{([^}]*)\}", lambda m: "{" + filt + ("," + m.group(1) if m.group(1).strip() else "") + "}", expr, count=1)
    return expr


def patch_redis_by(expr: str) -> str:
    for old, new in (
        ("by (cmd)", "by (cmd, redis_role, redis_instance, redis_port)"),
        ("by (db, instance)", "by (db, redis_role, redis_instance, redis_port)"),
        ("by (instance)", "by (redis_role, redis_instance, redis_port)"),
    ):
        if old in expr and new not in expr:
            expr = expr.replace(old, new)
    return expr


def patch_redis_legend(text: str) -> str:
    if not text or "{{redis_role}}" in text:
        return text
    text = text.replace("{{ instance }}", REDIS_LEGEND)
    text = re.sub(r",\s*\{\{\s*instance\s*\}\}", f", {REDIS_LEGEND}", text)
    if text in ("connected", "blocked", "hits", "misses"):
        return f"{text}, {REDIS_LEGEND}"
    if text == "{{ cmd }}":
        return f"{REDIS_LEGEND} — {{{{cmd}}}}"
    if text == "{{ input }}":
        return f"net in, {REDIS_LEGEND}"
    if text == "{{ output }}":
        return f"net out, {REDIS_LEGEND}"
    return text


def patch_memcached_expr(expr: str) -> str:
    if "memcached_" not in expr:
        return expr
    role_filt = 'memcached_role=~"$memcached_role"'
    inst_filt = 'instance=~"$instance"'
    job_filt = 'job=~"$job"'
    if job_filt not in expr:
        expr = re.sub(
            r"(memcached_\w+)\{",
            rf"\1{{{job_filt}, {role_filt}, {inst_filt}, ",
            expr,
            count=1,
        )
        return expr
    if role_filt not in expr:
        expr = expr.replace(job_filt, f"{job_filt}, {role_filt}")
    if inst_filt not in expr and "{" in expr and role_filt in expr:
        expr = expr.replace(role_filt, f"{role_filt}, {inst_filt}")
    return expr


def patch_memcached_by(expr: str) -> str:
    if " by (command)" in expr and "memcached_role" not in expr:
        return expr.replace(" by (command)", " by (command, memcached_role, memcached_port)")
    return expr


def patch_memcached_legend(text: str) -> str:
    if not text or "{{memcached_role}}" in text:
        return text
    plain = {
        "Memory used": "memory",
        "Get": "get",
        "Set": "set",
        "hit": "hit",
        "miss": "miss",
        "evicts": "evicts",
        "reclaims": "reclaims",
        "Connections": "connections",
        "Hit": "hit rate",
        "read": "read",
        "write": "write",
        "Memory": "memory %",
        "Items": "items",
        "QPS": "qps",
        "Hit Ratio": "hit ratio",
        "get": "get hit %",
        "delete": "delete hit %",
    }
    if text in plain:
        return f"{MEMCACHED_LEGEND} — {plain[text]}"
    if text == "{{command}}":
        return f"{MEMCACHED_LEGEND} — {{command}}"
    return text


def cluster_health_panel_redis() -> dict:
    return {
        "datasource": PROM_DS,
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
        "id": 9001,
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
                "datasource": PROM_DS,
                "expr": 'redis_up{job=~"$job", redis_role=~"$redis_role", redis_instance=~"$redis_instance", instance=~"$instance"}',
                "legendFormat": "{{redis_role}} {{redis_instance}} :{{redis_port}}",
                "refId": "A",
            }
        ],
        "title": "Redis — état primary / réplicas",
        "type": "stat",
    }


def cluster_health_panel_memcached() -> dict:
    return {
        "datasource": PROM_DS,
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
        "id": 9001,
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
                "datasource": PROM_DS,
                "expr": 'memcached_up{job=~"$job", memcached_role=~"$memcached_role", instance=~"$instance"}',
                "legendFormat": "{{memcached_role}} :{{memcached_port}}",
                "refId": "A",
            }
        ],
        "title": "Memcached — état primary / pools standby",
        "type": "stat",
    }


def shift_panels_y(panels: list, delta: int) -> None:
    for panel in panels:
        if "gridPos" in panel and panel.get("id") != 9001:
            panel["gridPos"]["y"] = panel["gridPos"].get("y", 0) + delta
        if panel.get("type") == "row" and panel.get("panels"):
            shift_panels_y(panel["panels"], delta)


def patch_redis(dash: dict) -> dict:
    def fix_panel(panel: dict) -> None:
        for target in panel.get("targets") or []:
            if isinstance(target.get("expr"), str):
                target["expr"] = patch_redis_by(patch_redis_expr(target["expr"]))
            if isinstance(target.get("legendFormat"), str):
                target["legendFormat"] = patch_redis_legend(target["legendFormat"])

    walk_panels(dash.get("panels") or [], fix_panel)

    if not any(p.get("id") == 9001 for p in dash.get("panels") or []):
        shift_panels_y(dash["panels"], 4)
        dash["panels"].insert(0, cluster_health_panel_redis())

    dash["templating"] = {
        "list": [
            var_query("job", "label_values(redis_up, job)", "Job Prometheus"),
            var_query(
                "redis_role",
                'label_values(redis_up{job=~"$job"}, redis_role)',
                "Rôle",
            ),
            var_query(
                "redis_instance",
                'label_values(redis_up{job=~"$job", redis_role=~"$redis_role"}, redis_instance)',
                "Cluster Redis",
            ),
            var_query(
                "instance",
                'label_values(redis_up{job=~"$job", redis_role=~"$redis_role", redis_instance=~"$redis_instance"}, instance)',
                "Exporter",
            ),
        ]
    }
    dash["description"] = (
        "Redis cache + BullMQ — primary et réplicas (labels redis_role, redis_instance, redis_port). "
        "Filtres en haut : Rôle = primary | replica, Cluster = cache | bullmq."
    )
    return dash


def patch_memcached(dash: dict) -> dict:
    def fix_panel(panel: dict) -> None:
        for target in panel.get("targets") or []:
            if isinstance(target.get("expr"), str):
                target["expr"] = patch_memcached_by(patch_memcached_expr(target["expr"]))
            if isinstance(target.get("legendFormat"), str):
                target["legendFormat"] = patch_memcached_legend(target["legendFormat"])

    walk_panels(dash.get("panels") or [], fix_panel)

    if not any(p.get("id") == 9001 for p in dash.get("panels") or []):
        shift_panels_y(dash["panels"], 4)
        dash["panels"].insert(0, cluster_health_panel_memcached())

    dash["templating"] = {
        "list": [
            var_query("job", "label_values(memcached_up, job)", "Job Prometheus"),
            var_query(
                "memcached_role",
                'label_values(memcached_up{job=~"$job"}, memcached_role)',
                "Rôle",
            ),
            var_query(
                "instance",
                'label_values(memcached_up{job=~"$job", memcached_role=~"$memcached_role"}, instance)',
                "Exporter",
            ),
        ]
    }
    dash["description"] = (
        "Memcached primary + pools standby (labels memcached_role, memcached_port). "
        "Rôle = primary | replica — ne pas agréger les 3 pools sauf comparaison."
    )
    return dash


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <redis.json> <memcached.json>", file=sys.stderr)
        sys.exit(1)

    redis_path = Path(sys.argv[1])
    memcached_path = Path(sys.argv[2])

    with redis_path.open(encoding="utf-8") as f:
        redis_dash = patch_redis(json.load(f))
    with redis_path.open("w", encoding="utf-8") as f:
        json.dump(redis_dash, f, indent=2)
        f.write("\n")

    with memcached_path.open(encoding="utf-8") as f:
        memcached_dash = patch_memcached(json.load(f))
    with memcached_path.open("w", encoding="utf-8") as f:
        json.dump(memcached_dash, f, indent=2)
        f.write("\n")

    print(f"Patched {redis_path}")
    print(f"Patched {memcached_path}")


if __name__ == "__main__":
    main()
