#!/usr/bin/env bash
# Déploie kube-state-metrics pour Prometheus/Grafana (pods k8s).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../monitoring/kube-state-metrics.yaml"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(sudo k3s kubectl)
fi

"${KUBECTL[@]}" apply -f "${MANIFEST}"
"${KUBECTL[@]}" rollout status deployment/kube-state-metrics -n kube-system --timeout=120s
echo "kube-state-metrics → http://127.0.0.1:30080/metrics"
