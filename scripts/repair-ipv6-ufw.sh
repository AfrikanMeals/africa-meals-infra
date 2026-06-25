#!/usr/bin/env bash
# Répare pare-feu + hairpin pour accès clients IPv6-only (AAAA Cloudflare).
# À lancer sur le VPS après ajout des enregistrements AAAA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

log "IPv6 VPS attendu : ${VPS_IPV6_ADDR}"
log "Domaines DNS-only (A + AAAA) : ${REDIS_TLS_DOMAIN}, ${EMQX_BROKER_DOMAIN}"

ensure_ufw_ipv6_enabled

for port in 6381 6382 6383 6384 6385 6386; do
  ufw_allow_tcp_port "${port}" "Stunnel Redis TLS :${port}"
done
ufw_allow_tcp_port "${MEMCACHED_TLS_PORT}" 'Stunnel Memcached TLS'
ufw_allow_tcp_port "${EMQX_MQTTS_PORT}" "nginx MQTTS ${EMQX_BROKER_DOMAIN}"
ufw_allow_tcp_port "${EMQX_WSS_PORT}" "nginx WSS ${EMQX_BROKER_DOMAIN}"

if command -v ufw >/dev/null 2>&1; then
  ufw reload
fi

bash "${SCRIPT_DIR}/repair-vps-mqtt-broker-hosts.sh"

log "Vérification écoute dual-stack (extrait) :"
ss -tlnp 2>/dev/null | grep -E '638[1-6]|:8883|:8884|\[::\]:8883|\[::\]:8884' | sed 's/^/[wise-eat]   /' || warn "Ports non visibles — relancer stunnel / emqx-broker"

log "Terminé. Depuis un client IPv6 : ./scripts/verify-ipv6-endpoints.sh"
