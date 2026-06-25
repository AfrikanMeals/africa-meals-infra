#!/usr/bin/env bash
# Répare nginx quand « unknown directive "stream" » ou symlink modules-enabled cassé.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

log "=== Repair nginx stream (EMQX MQTTS) ==="

remove_broken_nginx_module_symlinks
ensure_nginx_stream_module

if nginx -t 2>/dev/null; then
  systemctl reload nginx
  log "OK  nginx réparé et rechargé"
  exit 0
fi

nginx_err="$(nginx -t 2>&1 || true)"
log "Diagnostic : ${nginx_err}"

ensure_nginx_stream_include

if nginx -t; then
  systemctl reload nginx
  log "OK  nginx réparé et rechargé"
else
  warn "nginx -V stream :"
  nginx -V 2>&1 | tr ' ' '\n' | grep stream | sed 's/^/[wise-eat]      /' || true
  warn "share/modules-available :"
  ls -la /usr/share/nginx/modules-available/ 2>/dev/null | sed 's/^/[wise-eat]      /' || true
  warn "etc/modules-enabled :"
  ls -la /etc/nginx/modules-enabled/ 2>/dev/null | sed 's/^/[wise-eat]      /' || true
  warn "ngx_stream_module.so :"
  find_nginx_stream_module_so 2>/dev/null | sed 's/^/[wise-eat]      /' || warn "      (introuvable)"
  die "Correction manuelle requise — voir ci-dessus"
fi
