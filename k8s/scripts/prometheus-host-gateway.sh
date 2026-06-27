#!/usr/bin/env bash
# IP hôte joignable depuis le conteneur wise-eat-prometheus (sans dépendre de host.docker.internal).
set -euo pipefail

prometheus_resolve_host_gateway() {
  local ip="${PROMETHEUS_HOST_GATEWAY_IP:-}"

  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
    ip="$(docker exec wise-eat-prometheus getent hosts host.docker.internal 2>/dev/null \
      | awk '{print $1}' | head -1 || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    ip="$(docker exec wise-eat-prometheus ip route 2>/dev/null \
      | awk '/default/ {print $3; exit}' || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
  fi

  ip="$(docker network inspect wise-eat-infra -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null \
    | head -1 || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  ip="$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1 || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  return 1
}

prometheus_host_gateway_warn() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wise-eat-prometheus'; then
    if ! docker exec wise-eat-prometheus getent hosts host.docker.internal >/dev/null 2>&1; then
      echo "host.docker.internal absent dans wise-eat-prometheus — utilisation IP passerelle Docker." >&2
      echo "  Pour corriger : cd /opt/wise-eat/monitoring && docker compose up -d --force-recreate prometheus" >&2
    fi
  fi
}
