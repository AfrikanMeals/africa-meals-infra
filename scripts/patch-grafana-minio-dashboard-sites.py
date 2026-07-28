#!/usr/bin/env python3
"""Post-patch dashboard MinIO : sites primary/replicas + fallbacks buckets/objets."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROM_UID = "prometheus"
DS = {"type": "prometheus", "uid": PROM_UID}
# Jobs scrape (cluster + node + bucket) ; filtre site via minio_site / instance.
JOBS = "minio-cluster|minio-node|minio-bucket|minio"
JOB_FILTER = f'job=~"{JOBS}"'
# Variable Grafana — primary + replica-1 + replica-2
SITE_FILTER = 'minio_site=~"$minio_site"'
INSTANCE_FILTER = 'instance=~"$instance"'


def walk(obj, fn):
    if isinstance(obj, dict):
        fn(obj)
        for v in obj.values():
            walk(v, fn)
    elif isinstance(obj, list):
        for item in obj:
            walk(item, fn)


def patch_expr(expr: str) -> str:
    # Élargir jobs + ancrer filtre site (primary / replicas).
    expr = re.sub(
        r'job=~"minio-cluster\|minio-node\|minio"',
        f'job=~"{JOBS}", {SITE_FILTER}',
        expr,
    )
    expr = re.sub(
        r'job=~"minio-cluster\|minio-node\|minio-bucket\|minio"',
        f'job=~"{JOBS}", {SITE_FILTER}',
        expr,
    )
    # Éviter double SITE_FILTER si déjà patché.
    while f"{SITE_FILTER}, {SITE_FILTER}" in expr:
        expr = expr.replace(f"{SITE_FILTER}, {SITE_FILTER}", SITE_FILTER)

    # Buckets / objets : PAS de filtre minio_site (variable All / label manquant → N/A).
    if "minio_cluster_bucket_total" in expr:
        expr = (
            'max(minio_cluster_bucket_total{job=~"minio-cluster|minio-bucket|minio"}) '
            'or count(count by (bucket) '
            '(minio_bucket_usage_total_bytes{job=~"minio-bucket|minio-cluster|minio"})) '
            'or count(count by (bucket) '
            '(minio_bucket_usage_object_total{job=~"minio-bucket|minio-cluster|minio"}))'
        )

    if "minio_cluster_usage_object_total" in expr:
        # size_distribution = comptes par tranche de taille (souvent dispo avant usage_object_total).
        expr = (
            'max(minio_cluster_usage_object_total{job=~"minio-cluster|minio-bucket|minio"}) '
            'or sum(minio_bucket_usage_object_total{job=~"minio-bucket|minio-cluster|minio"}) '
            'or sum(minio_cluster_objects_size_distribution{job=~"minio-cluster|minio"})'
        )

    # Servers online : compter les sites scrapés UP (site replication = 3 standalone).
    if "minio_cluster_nodes_online_total" in expr:
        expr = f'count(up{{job="minio-cluster", {SITE_FILTER}}} == 1)'

    return expr


def patch_target(t: dict) -> None:
    if "expr" in t and isinstance(t["expr"], str):
        t["expr"] = patch_expr(t["expr"])


def fix_bucket_object_panels(panels: list) -> None:
    """Retirer mapping null→N/A et forcer requêtes robustes sur les stats buckets/objets."""
    for p in panels:
        title = (p.get("title") or "").strip()
        if title not in ("Number of Buckets", "Number of Objects"):
            continue
        # Plus de « N/A » vert trompeur quand la série est vide.
        defaults = p.setdefault("fieldConfig", {}).setdefault("defaults", {})
        defaults["mappings"] = []
        defaults["noValue"] = "—"
        opts = p.setdefault("options", {})
        opts.setdefault("reduceOptions", {})["calcs"] = ["lastNotNull"]
        for t in p.get("targets", []):
            if title == "Number of Buckets":
                t["expr"] = (
                    'max(minio_cluster_bucket_total{job=~"minio-cluster|minio-bucket|minio"}) '
                    'or count(count by (bucket) '
                    '(minio_bucket_usage_total_bytes{job=~"minio-bucket|minio-cluster|minio"})) '
                    'or count(count by (bucket) '
                    '(minio_bucket_usage_object_total{job=~"minio-bucket|minio-cluster|minio"}))'
                )
            else:
                t["expr"] = (
                    'max(minio_cluster_usage_object_total{job=~"minio-cluster|minio-bucket|minio"}) '
                    'or sum(minio_bucket_usage_object_total{job=~"minio-bucket|minio-cluster|minio"}) '
                    'or sum(minio_cluster_objects_size_distribution{job=~"minio-cluster|minio"})'
                )
            t["instant"] = True


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
                "expr": f'up{{job="minio-cluster", {SITE_FILTER}}}',
                "instant": True,
                "format": "time_series",
                "legendFormat": "{{minio_site}}",
                "refId": "A",
            },
            {
                "datasource": DS,
                "expr": f"max(minio_cluster_health_status{{{JOB_FILTER}, {SITE_FILTER}}})",
                "instant": True,
                "format": "time_series",
                "legendFormat": "cluster health ({{minio_site}})",
                "refId": "B",
            },
        ],
        "title": "MinIO — scrape Prometheus / santé (primary + replicas)",
        "type": "stat",
    }


def templating() -> dict:
    return {
        "list": [
            {
                "name": "minio_site",
                "label": "MinIO site (cluster / replicas)",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{job=~"{JOBS}"}}, minio_site)',
                "query": {
                    "query": f'label_values(up{{job=~"{JOBS}"}}, minio_site)',
                    "refId": "StandardVariableQuery",
                },
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "sort": 1,
                "hide": 0,
                "regex": "",
                "current": {"selected": True, "text": "All", "value": "$__all"},
                "allValue": "primary|replica-1|replica-2",
            },
            {
                "name": "instance",
                "label": "Instance",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{job=~"{JOBS}", minio_site=~"$minio_site"}}, instance)',
                "query": {
                    "query": f'label_values(up{{job=~"{JOBS}", minio_site=~"$minio_site"}}, instance)',
                    "refId": "StandardVariableQuery",
                },
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "sort": 1,
                "hide": 0,
                "regex": "",
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
            {
                "name": "scrape_jobs",
                "label": "Prometheus job",
                "type": "query",
                "datasource": DS,
                "definition": f'label_values(up{{job=~"{JOBS}"}}, job)',
                "query": {
                    "query": f'label_values(up{{job=~"{JOBS}"}}, job)',
                    "refId": "StandardVariableQuery",
                },
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "hide": 0,
                "regex": "",
                "current": {"selected": True, "text": "All", "value": "$__all"},
            },
        ]
    }


def main() -> None:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parents[1] /
                "monitoring/grafana/dashboards/MinIO/minio-storage.json")
    dash = json.loads(path.read_text(encoding="utf-8"))

    dash["description"] = (
        "Métriques MinIO (Prometheus) — primary :9000 + replica-1 :9002 + replica-2 :9004. "
        "Filtrer via « MinIO site ». Buckets/objets : cluster_* ou fallback /metrics/bucket. "
        "KMS : N/A si chiffrement KMS désactivé (attendu)."
    )

    walk(dash, lambda o: patch_target(o) if "expr" in o else None)

    panels = dash.get("panels", [])
    fix_bucket_object_panels(panels)
    # Remplacer panneau santé custom s'il existe, sinon insérer.
    panels = [p for p in panels if p.get("id") != 9200]
    for p in panels:
        if isinstance(p.get("gridPos"), dict) and "y" in p["gridPos"]:
            p["gridPos"]["y"] = int(p["gridPos"]["y"]) + 0  # no-op keep
    # S'assurer que le panneau santé est en y=0 ; bump si premier n'est pas 9200
    if not panels or panels[0].get("id") != 9200:
        for p in panels:
            gp = p.get("gridPos")
            if isinstance(gp, dict) and "y" in gp:
                gp["y"] = int(gp["y"]) + 4
        panels.insert(0, health_panel())
    else:
        panels[0] = health_panel()

    dash["panels"] = panels
    dash["templating"] = templating()
    dash["uid"] = "wise-eat-minio-20826"
    dash["title"] = "Wise Eat — MinIO Storage"

    path.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
    print(f"Patched sites/replicas → {path}")


if __name__ == "__main__":
    main()
