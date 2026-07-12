#!/usr/bin/env bash
# Sync Let's Encrypt → PEM HAProxy (fullchain + privkey concaténés).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

REDIS_TLS_DOMAIN="${REDIS_TLS_DOMAIN:-cache.wise-eat.com}"
MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
DEST="${HAPROXY_CERTS_DIR:-/etc/haproxy/certs}"
mkdir -p "${DEST}"

combine_pem() {
  local domain="$1"
  local out="${DEST}/${domain}.pem"
  local le="/etc/letsencrypt/live/${domain}"
  if [[ ! -f "${le}/fullchain.pem" || ! -f "${le}/privkey.pem" ]]; then
    warn "Cert LE absent pour ${domain} — skip ${out}"
    return 1
  fi
  cat "${le}/fullchain.pem" "${le}/privkey.pem" > "${out}"
  chmod 640 "${out}"
  chown root:haproxy "${out}" 2>/dev/null || chown root:root "${out}"
  log "HAProxy cert : ${out}"
}

combine_pem "${REDIS_TLS_DOMAIN}" || true
combine_pem "${MONGO_TLS_DOMAIN}" || true

if [[ "${HAPROXY_SKIP_RELOAD:-}" != "1" ]] && systemctl is-active haproxy >/dev/null 2>&1; then
  if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
    systemctl reload haproxy || systemctl restart haproxy
    log "haproxy rechargé (certs)"
  else
    warn "haproxy.cfg invalide — pas de reload"
  fi
fi
