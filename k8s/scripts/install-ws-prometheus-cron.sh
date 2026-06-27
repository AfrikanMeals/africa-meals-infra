#!/usr/bin/env bash
# Timer systemd — resync cibles Prometheus WS après rollout k8s (IP pods changent).
# Usage : sudo ./install-ws-prometheus-cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${SCRIPT_DIR}/sync-prometheus-ws-targets.sh"
UNIT="/etc/systemd/system/wise-eat-ws-prometheus-sync.service"
TIMER="/etc/systemd/system/wise-eat-ws-prometheus-sync.timer"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Exécuter en root : sudo $0" >&2
  exit 1
fi

cat > "${UNIT}" <<EOF
[Unit]
Description=Sync Prometheus targets africa-meals-ws (k8s)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SYNC}
EOF

cat > "${TIMER}" <<EOF
[Unit]
Description=Resync Prometheus WS targets every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now wise-eat-ws-prometheus-sync.timer
echo "Timer actif : systemctl status wise-eat-ws-prometheus-sync.timer"
