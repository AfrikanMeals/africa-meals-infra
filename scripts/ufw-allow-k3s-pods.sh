#!/usr/bin/env bash
# Autorise le CIDR pods k3s (10.42.0.0/24) vers Mongo/Redis/Memcached plaintext
# publiés sur la passerelle CNI (host.k3s.internal → 10.42.0.1).
# Stunnel TLS (27018, 6381…) reste géré par install-stunnel / ufw-allow-api-vps.
#
# Usage : sudo ./ufw-allow-k3s-pods.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

POD_CIDR="${K3S_POD_CIDR:-10.42.0.0/24}"

command -v ufw >/dev/null 2>&1 || die "ufw absent"

# Mongo rs0
for port in 27017 27027 27028; do
  ufw allow from "${POD_CIDR}" to any port "${port}" proto tcp comment "k3s pods Mongo :${port}" || true
done

# Redis cache + BullMQ (+ réplicas cluster-b)
for port in 6379 6380 6371 6372 6390 6391; do
  ufw allow from "${POD_CIDR}" to any port "${port}" proto tcp comment "k3s pods Redis :${port}" || true
done

# Memcached
for port in 11211 11213 11214; do
  ufw allow from "${POD_CIDR}" to any port "${port}" proto tcp comment "k3s pods Memcached :${port}" || true
done

ufw reload
log "UFW : ${POD_CIDR} → Mongo/Redis/Memcached plaintext OK"
log "Les ports restent aussi bindés sur 127.0.0.1 (PM2) et ${K3S_CNI_GATEWAY:-10.42.0.1} (pods)."
