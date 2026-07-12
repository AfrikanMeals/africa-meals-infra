#!/usr/bin/env bash
# Répare HAProxy TLS + UI proxy.wise-eat.com
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Réparation HAProxy ==="

command -v haproxy >/dev/null 2>&1 || die "haproxy absent — sudo ./install.sh haproxy"

HAPROXY_SKIP_RELOAD=1 bash "${SCRIPT_DIR}/sync-haproxy-certs.sh"
bash "${SCRIPT_DIR}/haproxy-free-tls-ports.sh"
cp "${INFRA_ROOT}/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg || die "haproxy.cfg invalide"
systemctl enable haproxy
systemctl restart haproxy

bash "${SCRIPT_DIR}/install-haproxy-proxy.sh" 2>/dev/null || true
if [[ -f "/etc/letsencrypt/live/${HAPROXY_PROXY_DOMAIN:-proxy.wise-eat.com}/fullchain.pem" ]]; then
  bash "${SCRIPT_DIR}/enable-haproxy-proxy-ssl.sh" 2>/dev/null || true
fi

systemctl status haproxy --no-pager || true
ss -lntp | grep -E 'haproxy|27018|6381|6382|11212|8404' || true
log "Test : curl -sS http://127.0.0.1:8404/metrics | head"
log "UI : https://${HAPROXY_PROXY_DOMAIN:-proxy.wise-eat.com}/stats"
