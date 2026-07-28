#!/usr/bin/env bash
# Cibles EMQX réplicas pour Prometheus (network_mode=host).
# Préfère les pod IPs k8s ; fallback Docker inspect (pre-cutover).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TARGETS_DIR="${MON_DIR}/prometheus/targets"
TARGETS_FILE="${TARGETS_DIR}/emqx-docker.json"
NAMESPACE="${K8S_NAMESPACE:-wise-eat}"

mkdir -p "${TARGETS_DIR}"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

# IP pod EMQX instance N (labels app.kubernetes.io/instance=2|3).
emqx_k8s_pod_ip() {
  local instance="$1"
  "${KUBECTL[@]}" -n "${NAMESPACE}" get pod \
    -l "app.kubernetes.io/name=emqx,app.kubernetes.io/instance=${instance}" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null | tr -d '[:space:]'
}

emqx_container_ip() {
  local name="$1"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}" 2>/dev/null \
    | tr -d '[:space:]'
}

{
  echo '['
  first=1
  for spec in \
    '2:wise-eat-emqx-2:1' \
    '3:wise-eat-emqx-3:2'; do
    instance="${spec%%:*}"
    rest="${spec#*:}"
    container="${rest%%:*}"
    replica="${rest##*:}"

    # 1) Prefer k8s pod IP (post cutover).
    ip="$(emqx_k8s_pod_ip "${instance}")"
    source_label="k8s"
    # 2) Fallback Docker (pre-cutover / rollback).
    if [[ -z "${ip}" ]]; then
      ip="$(emqx_container_ip "${container}")"
      source_label="docker"
    fi
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
      "emqx_scrape": "${container}",
      "emqx_source": "${source_label}"
    }
  }
EOF
  done
  echo
  echo ']'
} > "${TARGETS_FILE}"

echo "Cibles EMQX : ${TARGETS_FILE}"
cat "${TARGETS_FILE}"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
  curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null \
    && log "Prometheus rechargé (/-/reload)" \
    || warn "Reload Prometheus échoué — docker restart wise-eat-prometheus"
fi
