#!/usr/bin/env bash
# Répare nginx quand « unknown directive "stream" » (module stream absent ou mal chargé).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

log "=== Repair nginx stream (EMQX MQTTS) ==="

ensure_nginx_stream_module

if nginx -t 2>/dev/null; then
  log "OK  nginx -t déjà valide"
  systemctl reload nginx 2>/dev/null || true
  exit 0
fi

nginx_err="$(nginx -t 2>&1 || true)"
log "Diagnostic : ${nginx_err}"

if echo "${nginx_err}" | grep -q 'unknown directive "stream"'; then
  if ! nginx -V 2>&1 | grep -q 'with-stream'; then
    if [[ ! -e /etc/nginx/modules-enabled/50-mod-stream.conf ]]; then
      die "Module stream introuvable — essayer : sudo apt install -y libnginx-mod-stream nginx-full"
    fi
    warn "Module stream présent mais non chargé — vérifier include modules-enabled en tête de nginx.conf"
  fi
fi

ensure_nginx_stream_include

if nginx -t; then
  systemctl reload nginx
  log "OK  nginx réparé et rechargé"
else
  warn "nginx -t échoue encore — extrait nginx.conf (l.75-95) :"
  sed -n '75,95p' /etc/nginx/nginx.conf 2>/dev/null | sed 's/^/[wise-eat]      /' || true
  die "Correction manuelle requise sur /etc/nginx/nginx.conf"
fi
