#!/usr/bin/env bash
# Cibles EMQX réplicas (IP réseau Docker) pour Prometheus en network_mode=host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TARGETS_DIR="${MON_DIR}/prometheus/targets"
TARGETS_FILE="${TARGETS_DIR}/emqx-docker.json"

mkdir -p "${TARGETS_DIR}"

emqx_container_ip() {
  local name="$1"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}" 2>/dev/null \
    | tr -d '[:space:]'
}

{
  echo '['
  first=1
  for spec in \
    'wise-eat-emqx-2:1' \
    'wise-eat-emqx-3:2'; do
    container="${spec%%:*}"
    replica="${spec##*:}"
    ip="$(emqx_container_ip "${container}")"
    [[ -n "${ip}" ]] || continue
    [[ "${first}" -eq 1 ]] || echo ','
    first=0
    cat <<EOF
  {
    "targets": ["${ip}:18083"],
    "labels": {
      "namespace": "wise-eat",
      "emqx_role": "replica",
      "emqx_replica": "${replica}",
      "emqx_scrape": "${container}"
    }
  }
EOF
  done
  echo
  echo ']'
} > "${TARGETS_FILE}"

echo "Cibles EMQX Docker : ${TARGETS_FILE}"
cat "${TARGETS_FILE}"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null \
    && log "Prometheus rechargé (/-/reload)" \
    || warn "Reload Prometheus échoué — docker restart wise-eat-prometheus"
fi
