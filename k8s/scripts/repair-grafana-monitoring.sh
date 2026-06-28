#!/usr/bin/env bash
# Répare Grafana + Prometheus (node_exporter, k8s WS/API, dossier Servers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

if [[ -x "${INFRA_ROOT}/scripts/repair-grafana-stack.sh" ]]; then
  exec "${INFRA_ROOT}/scripts/repair-grafana-stack.sh"
fi

echo "Script repair-grafana-stack.sh introuvable — git pull dans ${INFRA_ROOT}" >&2
exit 1
