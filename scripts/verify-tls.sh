#!/usr/bin/env bash
# Vérifie les certificats Let's Encrypt (WS, Redis Stunnel, Grafana).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/certbot.sh
source "${SCRIPT_DIR}/lib/certbot.sh"

fail=0

check_le_file() {
  local label="$1"
  local domain="$2"
  if cert_exists "${domain}"; then
    log "OK  ${label} — /etc/letsencrypt/live/${domain}"
    openssl x509 -in "$(certbot_le_dir "${domain}")/fullchain.pem" -noout -subject -issuer -dates 2>/dev/null \
      | sed 's/^/[wise-eat]      /'
  else
    warn "MANQUANT ${label} — ${domain}"
    fail=1
  fi
}

check_le_file "WS nginx" "${WISE_EAT_DOMAIN}"
check_le_file "Redis Stunnel" "${REDIS_TLS_DOMAIN}"
check_le_file "Grafana console" "${GRAFANA_CONSOLE_DOMAIN}"

if command -v openssl >/dev/null 2>&1 && systemctl is-active stunnel4 >/dev/null 2>&1; then
  log "Stunnel local :11212 Memcached TLS (SNI ${REDIS_TLS_DOMAIN})"
  if nc -z 127.0.0.1 "${MEMCACHED_TLS_PORT}" 2>/dev/null; then
    memcached_issuer="$(echo | openssl s_client -connect "127.0.0.1:${MEMCACHED_TLS_PORT}" -servername "${REDIS_TLS_DOMAIN}" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)"
    if [[ -n "${memcached_issuer}" ]] && [[ "${memcached_issuer}" == *"Let's Encrypt"* ]]; then
      log "OK  Stunnel Memcached :${MEMCACHED_TLS_PORT} — Let's Encrypt"
    else
      warn "Stunnel Memcached :${MEMCACHED_TLS_PORT} — certificat non-LE ou injoignable"
      fail=1
    fi
  else
    warn "Port Stunnel Memcached :${MEMCACHED_TLS_PORT} fermé — lancer : sudo ./install.sh stunnel"
    fail=1
  fi

  log "Stunnel local :6381 (SNI ${REDIS_TLS_DOMAIN})"
  stunnel_issuer="$(echo | openssl s_client -connect "127.0.0.1:6381" -servername "${REDIS_TLS_DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)"
  if [[ -z "${stunnel_issuer}" ]]; then
    warn "Impossible de lire le certificat Stunnel :6381"
    fail=1
  elif [[ "${stunnel_issuer}" == *"Let's Encrypt"* ]]; then
    log "OK  Stunnel — certificat Let's Encrypt"
  else
    warn "Stunnel — certificat non-LE (${stunnel_issuer}) — lancer : STUNNEL_TLS_EMAIL=… ./install.sh tls"
    fail=1
  fi
fi

exit "${fail}"
