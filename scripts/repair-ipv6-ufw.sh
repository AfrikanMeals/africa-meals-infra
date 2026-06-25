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

log "Sync configs Stunnel (listeners IPv6 [::]:6381-6386, [::]:11212)…"
for primary_conf in redis-cache.conf redis-bullmq.conf; do
  cp "${STUNNEL_CONF_SRC}/${primary_conf}" /etc/stunnel/conf.d/
done
if redis_cluster_b_enabled; then
  for replica_conf in \
    redis-cache-replica-1.conf \
    redis-cache-replica-2.conf \
    redis-bullmq-replica-1.conf \
    redis-bullmq-replica-2.conf; do
    cp "${STUNNEL_CONF_SRC}/${replica_conf}" /etc/stunnel/conf.d/
  done
else
  rm -f /etc/stunnel/conf.d/redis-cache-replica-*.conf /etc/stunnel/conf.d/redis-bullmq-replica-*.conf
  log "Cluster-b désactivé — configs Stunnel réplicas retirées de conf.d"
fi
if [[ -f "${MEMCACHED_STUNNEL_CONF_SRC}/memcached-tls.conf" ]]; then
  cp "${MEMCACHED_STUNNEL_CONF_SRC}/memcached-tls.conf" /etc/stunnel/conf.d/
fi
if ! systemctl restart stunnel4; then
  warn "stunnel4 a échoué — journal (40 dernières lignes) :"
  journalctl -u stunnel4 -n 40 --no-pager 2>/dev/null || true
  die "Corrigez /etc/stunnel/conf.d puis : sudo systemctl restart stunnel4"
fi
log "stunnel4 redémarré"

bash "${SCRIPT_DIR}/repair-vps-mqtt-broker-hosts.sh"

log "Vérification écoute dual-stack (extrait) :"
ss -tlnp 2>/dev/null | grep -E '638[1-6]|:8883|:8884|\[::\]:638[1-6]|\[::\]:8883|\[::\]:8884|\[::\]:11212' | sed 's/^/[wise-eat]   /' \
  || warn "Ports non visibles — relancer stunnel / emqx-broker"

log "Terminé. Depuis un client IPv6 : ./scripts/verify-ipv6-endpoints.sh"
