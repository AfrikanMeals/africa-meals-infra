#!/usr/bin/env bash
# Vérifie que metrics-server répond (requis pour HPA CPU/mémoire sur k3s).
set -euo pipefail

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

WAIT_SECONDS="${METRICS_SERVER_WAIT_SECONDS:-60}"

if "${KUBECTL[@]}" top nodes >/dev/null 2>&1; then
  echo "metrics-server OK"
  exit 0
fi

echo "metrics-server indisponible — attente (${WAIT_SECONDS}s max)..."
for ((i = 1; i <= WAIT_SECONDS / 2; i++)); do
  if "${KUBECTL[@]}" top nodes >/dev/null 2>&1; then
    echo "metrics-server OK (après $((i * 2))s)"
    exit 0
  fi
  sleep 2
done

echo "ATTENTION: metrics-server absent ou non prêt — HPA CPU/mémoire inactif" >&2
echo "k3s: sudo k3s kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server" >&2
exit 1
