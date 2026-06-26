#!/usr/bin/env bash
# Vérifie résolution AAAA + connectivité TLS/MQTT via hostnames (depuis Mac ou VPS).
# Usage : ./scripts/verify-ipv6-endpoints.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VPS_IPV6="${VPS_IPV6_ADDR:-2a02:4780:75:447e::1}"
fail=0

check_aaaa() {
  local host="$1"
  local aaaa
  aaaa="$(dig +short AAAA "${host}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${aaaa}" ]]; then
    log "OK  AAAA ${host} → ${aaaa}"
  else
    warn "MANQUANT AAAA ${host} — ajouter ${VPS_IPV6} dans Cloudflare (DNS only pour ports non-HTTP)"
    fail=1
  fi
}

check_tcp6() {
  local host="$1" port="$2" label="$3"
  local aaaa ipv4
  aaaa="$(dig +short AAAA "${host}" 2>/dev/null | head -n 1 || true)"
  ipv4="$(dig +short A "${host}" 2>/dev/null | head -n 1 || true)"
  if ! command -v nc >/dev/null 2>&1; then
    warn "nc absent — skip TCP ${label}"
    return 0
  fi
  if [[ -n "${aaaa}" ]] && nc -z -G 2 -w 2 "${aaaa}" "${port}" 2>/dev/null; then
    log "OK  TCP6 ${label} ${host}:${port} via [${aaaa}]"
    return 0
  fi
  if [[ -n "${ipv4}" ]] && nc -z -G 2 -w 2 "${ipv4}" "${port}" 2>/dev/null; then
    log "OK  TCP4 ${label} ${host}:${port} via ${ipv4}"
    return 0
  fi
  warn "FAIL TCP ${label} ${host}:${port} (v6 et v4)"
  fail=1
}

check_tls_sni() {
  local host="$1" port="$2" label="$3"
  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl absent — skip TLS ${label}"
    return 0
  fi
  local aaaa ipv4 connect_target
  aaaa="$(dig +short AAAA "${host}" 2>/dev/null | head -n 1 || true)"
  ipv4="$(dig +short A "${host}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${aaaa}" ]] && nc -z -G 2 -w 2 "${aaaa}" "${port}" 2>/dev/null; then
    connect_target="[${aaaa}]:${port}"
  elif [[ -n "${ipv4}" ]] && nc -z -G 2 -w 2 "${ipv4}" "${port}" 2>/dev/null; then
    connect_target="${ipv4}:${port}"
  else
    warn "SKIP TLS ${label} ${host}:${port} — port fermé"
    fail=1
    return
  fi
  local issuer
  if command -v perl >/dev/null 2>&1; then
    issuer="$(echo | perl -e 'alarm shift; exec @ARGV' 5 openssl s_client -connect "${connect_target}" -servername "${host}" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)"
  else
    issuer="$(echo | openssl s_client -connect "${connect_target}" -servername "${host}" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)"
  fi
  if [[ -n "${issuer}" ]] && [[ "${issuer}" == *"Let's Encrypt"* ]]; then
    log "OK  TLS ${label} ${host}:${port} via ${connect_target} — Let's Encrypt"
  elif [[ -n "${issuer}" ]]; then
    warn "TLS ${label} ${host}:${port} via ${connect_target} — certificat non-LE"
    fail=1
  else
    warn "FAIL TLS ${label} ${host}:${port} via ${connect_target}"
    fail=1
  fi
}

log "=== Vérification IPv6 / dual-stack Wise Eat ==="
log "IPv6 VPS documenté : ${VPS_IPV6}"

for host in "${REDIS_TLS_DOMAIN}" "${EMQX_BROKER_DOMAIN}" "${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}" "${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}"; do
  check_aaaa "${host}"
done

check_tcp6 "${REDIS_TLS_DOMAIN}" 6381 "Redis Stunnel"
check_tcp6 "${REDIS_TLS_DOMAIN}" 6382 "BullMQ Stunnel"
check_tcp6 "${EMQX_BROKER_DOMAIN}" "${EMQX_MQTTS_PORT}" "MQTTS"
check_tcp6 "${EMQX_BROKER_DOMAIN}" "${EMQX_WSS_PORT}" "WSS"
check_tcp6 "${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}" 443 "Ollama HTTPS"

check_tls_sni "${REDIS_TLS_DOMAIN}" 6381 "Redis"
check_tls_sni "${EMQX_BROKER_DOMAIN}" "${EMQX_MQTTS_PORT}" "MQTTS"
check_tls_sni "${OLLAMA_GATEWAY_DOMAIN:-ai.wise-eat.com}" 443 "Ollama"

if [[ "${fail}" -eq 0 ]]; then
  log "Tous les tests OK - les apps gardent les hostnames dans .env"
else
  warn "Echecs detectes - sur le VPS : sudo ./install.sh repair-ipv6-ufw"
  warn "Verifier Hostinger : IPv6 active sur l interface reseau du VPS"
fi

exit "${fail}"
