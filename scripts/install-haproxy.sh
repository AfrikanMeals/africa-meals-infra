#!/usr/bin/env bash
# HAProxy TLS TCP (Mongo :27018, Redis :6381–6386, Memcached :11212) + UI proxy.wise-eat.com
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

REDIS_TLS_DOMAIN="${REDIS_TLS_DOMAIN:-cache.wise-eat.com}"
MONGO_TLS_DOMAIN="${MONGO_TLS_DOMAIN:-db.wise-eat.com}"
HAPROXY_PROXY_DOMAIN="${HAPROXY_PROXY_DOMAIN:-proxy.wise-eat.com}"
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"
HAPROXY_MODE="${HAPROXY_MODE:-lite}"
if [[ -n "${GCP_EGRESS_IP}" ]]; then
  HAPROXY_MODE="strict"
fi

apt update
apt install -y haproxy apache2-utils

mkdir -p /etc/haproxy/certs /run/haproxy /var/lib/haproxy
chown haproxy:haproxy /run/haproxy /var/lib/haproxy 2>/dev/null || true

# Certs LE requis
if [[ ! -f "/etc/letsencrypt/live/${REDIS_TLS_DOMAIN}/fullchain.pem" ]]; then
  if [[ -n "${STUNNEL_TLS_EMAIL:-}" ]]; then
    bash "${SCRIPT_DIR}/install-certbot.sh" || true
  else
    die "Certificat absent pour ${REDIS_TLS_DOMAIN} — STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls"
  fi
fi
if [[ ! -f "/etc/letsencrypt/live/${MONGO_TLS_DOMAIN}/fullchain.pem" ]]; then
  if [[ -n "${STUNNEL_TLS_EMAIL:-}" ]]; then
    bash "${SCRIPT_DIR}/install-mongodb-tls-acme.sh" 2>/dev/null || true
    certbot certonly --webroot -w "${CERTBOT_WEBROOT}" -d "${MONGO_TLS_DOMAIN}" \
      --email "${STUNNEL_TLS_EMAIL}" --agree-tos --non-interactive --keep-until-expiring 2>/dev/null || true
  fi
  [[ -f "/etc/letsencrypt/live/${MONGO_TLS_DOMAIN}/fullchain.pem" ]] || \
    die "Certificat absent pour ${MONGO_TLS_DOMAIN} — sudo ./install.sh mongodb-tls"
fi

HAPROXY_SKIP_RELOAD=1 bash "${SCRIPT_DIR}/sync-haproxy-certs.sh"
[[ -f "/etc/haproxy/certs/${REDIS_TLS_DOMAIN}.pem" ]] || die "PEM cache manquant"
[[ -f "/etc/haproxy/certs/${MONGO_TLS_DOMAIN}.pem" ]] || die "PEM mongo manquant"

# Libérer Stunnel / socat
bash "${SCRIPT_DIR}/haproxy-free-tls-ports.sh"

# Installer config
cp "${INFRA_ROOT}/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
chmod 644 /etc/haproxy/haproxy.cfg

haproxy -c -f /etc/haproxy/haproxy.cfg || die "haproxy.cfg invalide"
systemctl enable haproxy
systemctl restart haproxy

# UFW
if command -v ufw >/dev/null 2>&1; then
  ensure_ufw_ipv6_enabled
  if [[ "${HAPROXY_MODE}" == "strict" ]]; then
    log "Mode A-strict — UFW depuis ${GCP_EGRESS_IP}"
    for p in 6381 6382 6383 6384 6385 6386 11212 27018; do
      ufw deny "${p}"/tcp 2>/dev/null || true
      ufw allow from "${GCP_EGRESS_IP}" to any port "${p}" proto tcp comment "GCP CF HAProxy :${p}"
    done
  else
    log "Mode A-lite — ports TLS publics"
    for p in 6381 6382 6383 6384 6385 6386; do
      ufw_allow_tcp_port "${p}" "HAProxy Redis TLS :${p}"
    done
    ufw_allow_tcp_port 11212 "HAProxy Memcached TLS"
    ufw_allow_tcp_port 27018 "HAProxy MongoDB TLS"
  fi
  ufw reload 2>/dev/null || true
fi

# UI publique
bash "${SCRIPT_DIR}/install-haproxy-proxy.sh"

# Vérifs locales
ok=1
for port in 27018 6381 6382 11212; do
  if ss -lntp 2>/dev/null | grep -qE ":${port}\\b.*haproxy"; then
    log "OK  HAProxy :${port}"
  else
    warn "Port :${port} — haproxy non visible"
    ok=0
  fi
done

if command -v openssl >/dev/null 2>&1; then
  echo | openssl s_client -connect "127.0.0.1:6381" -servername "${REDIS_TLS_DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer 2>/dev/null || warn "TLS :6381 local KO"
  echo | openssl s_client -connect "127.0.0.1:27018" -servername "${MONGO_TLS_DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer 2>/dev/null || warn "TLS :27018 local KO"
fi

systemctl status haproxy --no-pager || true
[[ "${ok}" == "1" ]] || warn "Certains ports manquent — journalctl -u haproxy -n 50"

log "HAProxy actif — rediss://${REDIS_TLS_DOMAIN}:6381 · memcached ${REDIS_TLS_DOMAIN}:11212 · mongo ${MONGO_TLS_DOMAIN}:27018"
log "Stats UI : https://${HAPROXY_PROXY_DOMAIN}/stats (basic auth)"
log "Prometheus scrape : http://127.0.0.1:8404/metrics"
