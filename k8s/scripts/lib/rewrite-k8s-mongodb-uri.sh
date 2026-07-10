#!/usr/bin/env bash
# Réécrit MONGODB_URI pour les pods k3s : accès local via host.k3s.internal
# sur les ports Mongo plaintext (27017/27027/27028) + replicaSet=rs0.
#
# Stunnel :27018 reste réservé à l’accès distant / admin (pas utilisé depuis les pods —
# ECONNRESET récurrent via cni0 → Stunnel TLS).
#
# Usage (sourcer puis appeler) :
#   rewrite_k8s_mongodb_uri_in_file /path/to/filtered.env host.k3s.internal
rewrite_k8s_mongodb_uri_in_file() {
  local file="${1:?fichier env requis}"
  local local_host="${2:-host.k3s.internal}"

  if [[ ! -f "${file}" ]] || ! grep -q '^MONGODB_URI=mongodb://' "${file}"; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 requis pour réécrire MONGODB_URI (rs0 local)." >&2
    return 1
  fi

  python3 - "${file}" "${local_host}" <<'PY'
import re
import sys
import urllib.parse

path, local_host = sys.argv[1:3]
local_ports = ("27017", "27027", "27028")
stunnel_port = "27018"
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
    uses_local_or_stunnel = False
    for part in host_parts:
        if ":" in part:
            h, p = part.rsplit(":", 1)
        else:
            h, p = part, "27017"
        if (
            h in (local_host, "127.0.0.1", "localhost", "db.wise-eat.com")
            or p in local_ports
            or p == stunnel_port
            or h.endswith(".k3s.internal")
        ):
            uses_local_or_stunnel = True

    if not uses_local_or_stunnel:
        out.append(line)
        continue

    params = urllib.parse.parse_qs(qs or "", keep_blank_values=True)
    params.pop("tls", None)
    params.pop("ssl", None)
    params.pop("directConnection", None)
    params.pop("tlsAllowInvalidCertificates", None)
    params.pop("tlsAllowInvalidHostnames", None)
    params["replicaSet"] = ["rs0"]
    if "authSource" not in params:
        params["authSource"] = ["admin"]
    if "retryWrites" not in params:
        params["retryWrites"] = ["true"]
    if "w" not in params:
        params["w"] = ["majority"]

    seed = ",".join(f"{local_host}:{p}" for p in local_ports)
    new_qs = urllib.parse.urlencode({k: v[0] for k, v in params.items()})
    new_uri = f"mongodb://{creds}@{seed}/{db}?{new_qs}"
    out.append(f"MONGODB_URI={new_uri}")
    rewrote = True

with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + ("\n" if out else ""))

if rewrote:
    print(
        f"MONGODB_URI réécrit pour k8s local ({local_host}:27017|27027|27028, replicaSet=rs0, sans TLS)",
        file=sys.stderr,
    )
PY
}

# rediss://host:6381 → redis://host:6379 (et équivalents réplicas / BullMQ).
# Stunnel TLS depuis pods k3s via cni0 est instable (ECONNRESET) ; plaintext local + UFW 10.42.
rewrite_k8s_redis_urls_in_file() {
  local file="${1:?fichier env requis}"
  local local_host="${2:-host.k3s.internal}"

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 requis pour réécrire REDIS_*/BULLMQ_* URLs." >&2
    return 1
  fi

  python3 - "${file}" "${local_host}" <<'PY'
import re
import sys

path, local_host = sys.argv[1:3]
# Stunnel TLS port → backend plaintext Docker
port_map = {
    "6381": "6379",  # cache primary
    "6383": "6371",  # cache replica 1
    "6384": "6372",  # cache replica 2
    "6382": "6380",  # bull primary
    "6385": "6390",  # bull replica 1
    "6386": "6391",  # bull replica 2
}
keys = (
    "REDIS_URL",
    "REDIS_REPLICA_1_URL",
    "REDIS_REPLICA_2_URL",
    "BULLMQ_REDIS_URL",
    "BULLMQ_REDIS_REPLICA_1_URL",
    "BULLMQ_REDIS_REPLICA_2_URL",
)
lines = open(path, encoding="utf-8").read().splitlines()
out = []
rewrote = False

for line in lines:
    changed = False
    for key in keys:
        if line.startswith(f"{key}="):
            val = line.split("=", 1)[1].strip()
            # rediss://user:pass@host:PORT/... → redis://...@local_host:mapped/
            m = re.match(
                r"^(rediss?)://([^@]+)@([^:/]+):(\d+)(.*)$",
                val,
            )
            if not m:
                break
            scheme, creds, host, port, rest = m.groups()
            if host not in (
                local_host,
                "127.0.0.1",
                "localhost",
                "cache.wise-eat.com",
            ) and not host.endswith(".k3s.internal"):
                break
            new_port = port_map.get(port, port)
            # Toujours plaintext pour pods locaux
            new_val = f"redis://{creds}@{local_host}:{new_port}{rest}"
            out.append(f"{key}={new_val}")
            changed = True
            rewrote = True
            break
    if not changed:
        out.append(line)

with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + ("\n" if out else ""))

if rewrote:
    print(
        f"REDIS/BULLMQ URLs réécrits pour k8s local (redis://{local_host}, sans TLS Stunnel)",
        file=sys.stderr,
    )
PY
}
