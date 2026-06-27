#!/usr/bin/env bash
# Réécrit MONGODB_URI pour les pods k3s : ports Mongo locaux (27017/27027/27028)
# → Stunnel TLS unique (27018) + directConnection.
#
# Usage (sourcer puis appeler) :
#   rewrite_k8s_mongodb_uri_in_file /path/to/filtered.env host.k3s.internal 27018
rewrite_k8s_mongodb_uri_in_file() {
  local file="${1:?fichier env requis}"
  local local_host="${2:-host.k3s.internal}"
  local stunnel_port="${3:-27018}"

  if [[ ! -f "${file}" ]] || ! grep -q '^MONGODB_URI=mongodb://' "${file}"; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 requis pour réécrire MONGODB_URI (Stunnel :${stunnel_port})." >&2
    return 1
  fi

  python3 - "${file}" "${local_host}" "${stunnel_port}" <<'PY'
import re
import sys
import urllib.parse

path, local_host, stunnel_port = sys.argv[1:4]
local_ports = {"27017", "27027", "27028"}
lines = open(path, encoding="utf-8").read().splitlines()
out = []
rewrote = False

for line in lines:
    if not line.startswith("MONGODB_URI=mongodb://"):
        out.append(line)
        continue

    uri = line.split("=", 1)[1].strip()
    m = re.match(r"^mongodb://([^@]+)@([^/]+)/([^?]*)(\?(.*))?$", uri)
    if not m:
        out.append(line)
        continue

    creds, hosts, db, _, qs = m.groups()
    host_parts = [h.strip() for h in hosts.split(",") if h.strip()]
    ports = set()
    uses_local = False
    for part in host_parts:
        if ":" in part:
            h, p = part.rsplit(":", 1)
        else:
            h, p = part, "27017"
        ports.add(p)
        if (
            h in (local_host, "127.0.0.1", "localhost")
            or p in local_ports
            or h.endswith(".k3s.internal")
        ):
            uses_local = True

    if not uses_local and stunnel_port in ports and len(host_parts) == 1:
        out.append(line)
        continue

    if not uses_local:
        out.append(line)
        continue

    params = urllib.parse.parse_qs(qs or "", keep_blank_values=True)
    params.pop("replicaSet", None)
    if "authSource" not in params:
        params["authSource"] = ["admin"]
    params["tls"] = ["true"]
    params["directConnection"] = ["true"]
    if "retryWrites" not in params:
        params["retryWrites"] = ["true"]
    if "w" not in params:
        params["w"] = ["majority"]

    new_qs = urllib.parse.urlencode({k: v[0] for k, v in params.items()})
    new_uri = f"mongodb://{creds}@{local_host}:{stunnel_port}/{db}?{new_qs}"
    out.append(f"MONGODB_URI={new_uri}")
    rewrote = True

with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + ("\n" if out else ""))

if rewrote:
    print(
        f"MONGODB_URI réécrit pour Stunnel k8s ({local_host}:{stunnel_port}, directConnection)",
        file=sys.stderr,
    )
PY
}
