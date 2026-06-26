#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"
STUNNEL_AUTH_ONLY="${STUNNEL_AUTH_ONLY:-}"

if [[ -n "${GCP_EGRESS_IP}" ]]; then
  STUNNEL_MODE="strict"
elif [[ "${STUNNEL_AUTH_ONLY}" == "1" || -z "${STUNNEL_AUTH_ONLY}" ]]; then
  STUNNEL_MODE="lite"
  STUNNEL_AUTH_ONLY=1
else
  die "STUNNEL_AUTH_ONLY=0 sans GCP_EGRESS_IP — définir GCP_EGRESS_IP (A-strict) ou STUNNEL_AUTH_ONLY=1 (A-lite)"
fi

apt update
apt install -y stunnel4

mkdir -p /etc/stunnel/conf.d /etc/stunnel/certs

# TLS : Let's Encrypt (prod) ou auto-signé (fallback dev local uniquement)
if [[ -f "/etc/letsencrypt/live/${REDIS_TLS_DOMAIN}/fullchain.pem" ]]; then
  bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"
elif [[ -n "${STUNNEL_TLS_EMAIL:-}" ]]; then
  bash "${SCRIPT_DIR}/install-certbot.sh"
elif [[ "${ALLOW_SELF_SIGNED_STUNNEL:-}" == "1" ]]; then
  warn "Certificat auto-signé (dev) — prod : STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls"
  openssl req -new -x509 -days 825 -nodes \
    -out /etc/stunnel/certs/fullchain.pem \
    -keyout /etc/stunnel/certs/privkey.pem \
    -subj "/CN=${REDIS_TLS_DOMAIN}"
  chown root:stunnel4 /etc/stunnel/certs/fullchain.pem /etc/stunnel/certs/privkey.pem
  chmod 644 /etc/stunnel/certs/fullchain.pem
  chmod 640 /etc/stunnel/certs/privkey.pem
else
  die "Certificat Let's Encrypt absent pour ${REDIS_TLS_DOMAIN}. Lancer : STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls"
fi

ensure_stunnel_runtime
stunnel_sync_conf_d

systemctl enable stunnel4
stunnel_restart_or_die

if command -v ufw >/dev/null 2>&1; then
  ensure_ufw_ipv6_enabled
  if [[ "${STUNNEL_MODE}" == "strict" ]]; then
    log "Mode A-strict — UFW autorise ${GCP_EGRESS_IP} uniquement"
    for stunnel_port in 6381 6382 6383 6384 6385 6386; do
      ufw deny "${stunnel_port}"/tcp 2>/dev/null || true
      ufw allow from "${GCP_EGRESS_IP}" to any port "${stunnel_port}" proto tcp comment "GCP CF Redis Stunnel :${stunnel_port}"
    done
    ufw deny "${MEMCACHED_TLS_PORT}"/tcp 2>/dev/null || true
    ufw allow from "${GCP_EGRESS_IP}" to any port "${MEMCACHED_TLS_PORT}" proto tcp comment 'GCP CF Memcached TLS'
  else
    log "Mode A-lite (prod) — TLS Let's Encrypt + ACL Redis"
    for stunnel_port in 6381 6382 6383 6384 6385 6386; do
      ufw_allow_tcp_port "${stunnel_port}" "Stunnel Redis TLS :${stunnel_port}"
    done
    ufw_allow_tcp_port "${MEMCACHED_TLS_PORT}" 'Stunnel Memcached TLS'
    MONGO_TLS_PORT="${MONGO_TLS_PORT:-27018}"
    if [[ -f /etc/stunnel/conf.d/mongodb-tls.conf ]]; then
      ufw_allow_tcp_port "${MONGO_TLS_PORT}" "Stunnel MongoDB TLS :${MONGO_TLS_PORT}"
    fi
  fi
  ufw reload
else
  warn "ufw absent — configurer le pare-feu manuellement (v4 + v6 pour :6381-6386, :11212)"
fi

log "Stunnel ${STUNNEL_MODE} — rediss://${REDIS_TLS_DOMAIN}:6381-6386 · memcached TLS ${REDIS_TLS_DOMAIN}:${MEMCACHED_TLS_PORT}"
log "Dual-stack : ajouter AAAA ${VPS_IPV6_ADDR} sur ${REDIS_TLS_DOMAIN} (Cloudflare DNS only)"
if ss -tlnp 2>/dev/null | grep -qE '638[1-6]|\[::\]:638[1-6]'; then
  log "Ports Redis Stunnel actifs (6381 primary cache, 6382 primary bull, 6383-6384 cache réplicas, 6385-6386 bull réplicas)"
else
  warn "Ports Redis Stunnel (6381-6386) non visibles — cluster-b actif ? sudo ./install.sh redis"
fi
if ss -tlnp | grep -q ":${MEMCACHED_TLS_PORT}"; then
  log "Port Memcached TLS :${MEMCACHED_TLS_PORT} actif"
else
  warn "Port Memcached TLS :${MEMCACHED_TLS_PORT} absent — vérifier /etc/stunnel/conf.d/memcached-tls.conf et journalctl -u stunnel4"
fi
systemctl status stunnel4 --no-pager || true

# Vérification TLS (si openssl dispo)
if command -v openssl >/dev/null 2>&1; then
  echo | openssl s_client -connect "127.0.0.1:6381" -servername "${REDIS_TLS_DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer 2>/dev/null || true
  if ss -tlnp | grep -q ":${MEMCACHED_TLS_PORT}"; then
    echo | openssl s_client -connect "127.0.0.1:${MEMCACHED_TLS_PORT}" -servername "${REDIS_TLS_DOMAIN}" 2>/dev/null \
      | openssl x509 -noout -subject -issuer 2>/dev/null || warn "TLS Memcached :${MEMCACHED_TLS_PORT} injoignable en local"
  fi
fi
