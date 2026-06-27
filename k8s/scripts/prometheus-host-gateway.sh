#!/usr/bin/env bash
# Adresse utilisée par Prometheus pour joindre l'hôte VPS (k3s NodePort, relais socat).
set -euo pipefail

prometheus_uses_host_network() {
  local mode
  mode="$(docker inspect wise-eat-prometheus -f '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
  [[ "${mode}" == "host" ]]
}

prometheus_scrape_host() {
  if prometheus_uses_host_network; then
    printf '127.0.0.1\n'
    return 0
  fi
  prometheus_resolve_host_gateway
}

prometheus_resolve_host_gateway() {
  local ip="${PROMETHEUS_HOST_GATEWAY_IP:-}"

  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  if prometheus_uses_host_network; then
    printf '127.0.0.1\n'
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

host_can_reach_pod_metrics() {
  local pod_ip="${1:-}"
  [[ -n "${pod_ip}" ]] || return 1
  curl -sf --max-time 3 "http://${pod_ip}:8000/api/metrics" 2>/dev/null | grep -q ws_up
}

prometheus_host_gateway_warn() {
  if prometheus_uses_host_network; then
    echo "Prometheus en network_mode=host → scrape via 127.0.0.1 / IP pods k3s."
    return 0
  fi
  echo "Prometheus en réseau Docker — scrape hôte souvent bloqué (firewall / passerelle)." >&2
  echo "  Recommandé : sudo k8s/scripts/recreate-prometheus-host.sh" >&2
}
