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
check_le_file "API Nest (k8s)" "${API_WISE_EAT_DOMAIN}"
check_le_file "WS k8s" "${WS_WISE_EAT_DOMAIN}"
check_le_file "Redis / HAProxy TLS" "${REDIS_TLS_DOMAIN}"
check_le_file "Mongo TLS" "${MONGO_TLS_DOMAIN}"
check_le_file "HAProxy UI" "${HAPROXY_PROXY_DOMAIN}"
check_le_file "Grafana console" "${GRAFANA_CONSOLE_DOMAIN}"
check_le_file "EMQX broker" "${EMQX_BROKER_DOMAIN}"
check_le_file "EMQX dashboard" "${EMQX_WORKER_DOMAIN}"

if command -v openssl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "${EMQX_MQTTS_PORT}" 2>/dev/null; then
    emqx_issuer="$(echo | openssl s_client -connect "127.0.0.1:${EMQX_MQTTS_PORT}" -servername "${EMQX_BROKER_DOMAIN}" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)"
    if [[ -n "${emqx_issuer}" ]] && [[ "${emqx_issuer}" == *"Let's Encrypt"* ]]; then
      log "OK  nginx MQTTS :${EMQX_MQTTS_PORT} — Let's Encrypt"
    else
      warn "nginx MQTTS :${EMQX_MQTTS_PORT} — certificat non-LE ou injoignable"
      fail=1
    fi
  else
    warn "Port MQTTS :${EMQX_MQTTS_PORT} fermé — lancer : sudo ./install.sh emqx-broker"
  fi
fi

check_tcp_tls_front() {
  local label="$1"
  local port="$2"
  local sni="$3"
  if ! nc -z 127.0.0.1 "${port}" 2>/dev/null; then
    warn "Port :${port} fermé (${label})"
    fail=1
    return
  fi
  local issuer
  issuer="$(echo | openssl s_client -connect "127.0.0.1:${port}" -servername "${sni}" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)"
  if [[ -n "${issuer}" ]] && [[ "${issuer}" == *"Let's Encrypt"* ]]; then
    log "OK  ${label} :${port} — Let's Encrypt"
  else
    warn "${label} :${port} — certificat non-LE ou injoignable"
    fail=1
  fi
}

if command -v openssl >/dev/null 2>&1 && systemctl is-active haproxy >/dev/null 2>&1; then
  log "HAProxy TLS local"
  check_tcp_tls_front "HAProxy Redis" 6381 "${REDIS_TLS_DOMAIN}"
  check_tcp_tls_front "HAProxy Memcached" "${MEMCACHED_TLS_PORT}" "${REDIS_TLS_DOMAIN}"
  check_tcp_tls_front "HAProxy Mongo" "${MONGO_TLS_PORT}" "${MONGO_TLS_DOMAIN}"
elif command -v openssl >/dev/null 2>&1 && systemctl is-active stunnel4 >/dev/null 2>&1; then
  log "Stunnel local (legacy)"
  check_tcp_tls_front "Stunnel Memcached" "${MEMCACHED_TLS_PORT}" "${REDIS_TLS_DOMAIN}"
  check_tcp_tls_front "Stunnel Redis" 6381 "${REDIS_TLS_DOMAIN}"
else
  warn "Ni haproxy ni stunnel4 actifs — sudo ./install.sh haproxy"
  fail=1
fi

exit "${fail}"
