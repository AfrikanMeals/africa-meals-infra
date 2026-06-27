#!/usr/bin/env bash
# Timer systemd — resync cibles Prometheus API après rollout k8s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${SCRIPT_DIR}/sync-prometheus-api-targets.sh"
UNIT="/etc/systemd/system/wise-eat-api-prometheus-sync.service"
TIMER="/etc/systemd/system/wise-eat-api-prometheus-sync.timer"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

cat > "${UNIT}" <<EOF
[Unit]
Description=Sync Prometheus targets africa-meals-api (k8s)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SYNC}
EOF

cat > "${TIMER}" <<EOF
[Unit]
Description=Resync Prometheus API targets every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now wise-eat-api-prometheus-sync.timer
echo "Timer actif : systemctl status wise-eat-api-prometheus-sync.timer"
