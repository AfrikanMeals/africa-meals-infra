#!/usr/bin/env python3
"""Retire prometheus.collectors de cluster.hocon (conflit schéma legacy EMQX 5.8)."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def strip_prometheus_collectors(text: str) -> tuple[str, bool]:
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    changed = False
    while i < len(lines):
        line = lines[i]
        if re.match(r"\s*collectors\s*\{", line):
            changed = True
            depth = line.count("{") - line.count("}")
            i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count("{") - lines[i].count("}")
                i += 1
            continue
        out.append(line)
        i += 1
    return "".join(out), changed


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: fix-emqx-cluster-hocon-prometheus.py <cluster.hocon>...", file=sys.stderr)
        return 2
    patched = 0
    for arg in sys.argv[1:]:
        path = Path(arg)
        if not path.is_file():
            continue
        original = path.read_text(encoding="utf-8")
        fixed, changed = strip_prometheus_collectors(original)
        if changed:
            path.write_text(fixed, encoding="utf-8")
            print(f"Patched {path}")
            patched += 1
    return 0 if patched >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
