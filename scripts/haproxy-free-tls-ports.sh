#!/usr/bin/env bash
# Libère les ports TLS TCP (Stunnel / socat) avant démarrage HAProxy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

BAK="/root/stunnel-haproxy-migration-$(date +%Y%m%d)"
mkdir -p "${BAK}"

# Arrêt socat (workaround temporaire)
for svc in mongo-tls-socat redis-cache-tls-socat redis-bullmq-tls-socat \
  redis-cache-r1-tls-socat redis-cache-r2-tls-socat \
  redis-bull-r1-tls-socat redis-bull-r2-tls-socat \
  memcached-tls-socat; do
  if systemctl list-unit-files "${svc}.service" &>/dev/null; then
    systemctl disable --now "${svc}.service" 2>/dev/null || true
    log "Arrêt ${svc}"
  fi
done

# Retirer confs Stunnel qui bindent les ports HAProxy
shopt -s nullglob
moved=0
for f in /etc/stunnel/conf.d/mongodb-tls.conf* \
  /etc/stunnel/conf.d/redis-*.conf \
  /etc/stunnel/conf.d/memcached*.conf; do
  [[ -e "${f}" ]] || continue
  mv "${f}" "${BAK}/"
  moved=1
  log "Stunnel conf déplacée → ${BAK}/$(basename "${f}")"
done
shopt -u nullglob

if [[ "${moved}" == "1" ]] || systemctl is-active stunnel4 >/dev/null 2>&1; then
  if [[ -n "$(ls -A /etc/stunnel/conf.d 2>/dev/null || true)" ]]; then
    systemctl restart stunnel4 2>/dev/null || warn "stunnel4 restart échoué (conf restante ?)"
  else
    # Plus aucun service Stunnel — arrêter pour libérer proprement
    systemctl disable --now stunnel4 2>/dev/null || true
    log "stunnel4 arrêté (conf.d vide — HAProxy prend le relais)"
  fi
fi

# Attendre libération ports
sleep 1
for port in 27018 6381 6382 6383 6384 6385 6386 11212; do
  if ss -lntp 2>/dev/null | grep -qE ":${port}\\b"; then
    warn "Port :${port} encore occupé — ss -lntp | grep ${port}"
  fi
done
