#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"
STUNNEL_AUTH_ONLY="${STUNNEL_AUTH_ONLY:-}"

# Prod Wise Eat : A-lite par défaut (sans Cloud NAT). A-strict si GCP_EGRESS_IP est défini.
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

mkdir -p /etc/stunnel/conf.d

if [[ ! -f /etc/stunnel/redis.pem ]]; then
  log "Certificat TLS Stunnel auto-signé"
  openssl req -new -x509 -days 825 -nodes \
    -out /etc/stunnel/redis.pem -keyout /etc/stunnel/redis.pem \
    -subj "/CN=wise-eat.cloud"
  chmod 600 /etc/stunnel/redis.pem
fi

cp "${STUNNEL_CONF_SRC}/redis-cache.conf" /etc/stunnel/conf.d/
cp "${STUNNEL_CONF_SRC}/redis-bullmq.conf" /etc/stunnel/conf.d/

if ! grep -q 'include = /etc/stunnel/conf.d' /etc/stunnel/stunnel.conf 2>/dev/null; then
  cat >> /etc/stunnel/stunnel.conf <<'EOF'

; Wise Eat Mode A
setuid = stunnel4
setgid = stunnel4
pid = /var/run/stunnel4/stunnel.pid
include = /etc/stunnel/conf.d
EOF
fi

systemctl enable stunnel4
systemctl restart stunnel4

if command -v ufw >/dev/null 2>&1; then
  if [[ "${STUNNEL_MODE}" == "strict" ]]; then
    log "Mode A-strict — UFW autorise ${GCP_EGRESS_IP} uniquement"
    ufw deny 6381/tcp 2>/dev/null || true
    ufw deny 6382/tcp 2>/dev/null || true
    ufw allow from "${GCP_EGRESS_IP}" to any port 6381 proto tcp comment 'GCP CF Redis cache'
    ufw allow from "${GCP_EGRESS_IP}" to any port 6382 proto tcp comment 'GCP CF Redis BullMQ'
  else
    log "Mode A-lite (prod) — TLS + ACL Redis, sans Cloud NAT"
    ufw allow 6381/tcp comment 'Stunnel Redis cache A-lite'
    ufw allow 6382/tcp comment 'Stunnel Redis bull A-lite'
  fi
  ufw reload
else
  warn "ufw absent — configurer le pare-feu manuellement"
fi

log "Stunnel ${STUNNEL_MODE} — API : rediss://wise-eat-cache:***@wise-eat.cloud:6381"
ss -tlnp | grep -E '6381|6382' || warn "Ports Stunnel non visibles"
systemctl status stunnel4 --no-pager || true
