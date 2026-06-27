#!/usr/bin/env bash
# Bascule nginx ws.wise-eat.com → NodePort k3s (30800).
# Alias de install-ws-nginx.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install-ws-nginx.sh" "$@"
