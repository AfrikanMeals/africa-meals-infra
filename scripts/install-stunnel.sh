#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"
STUNNEL_AUTH_ONLY="${STUNNEL_AUTH_ONLY:-}"
STUNNEL_TLS_DOMAIN="${STUNNEL_TLS_DOMAIN:-wise-eat.cloud}"

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

# TLS : Let's Encrypt (prod) ou auto-signé (fallback dev)
if [[ -f "/etc/letsencrypt/live/${STUNNEL_TLS_DOMAIN}/fullchain.pem" ]]; then
  bash "${SCRIPT_DIR}/sync-stunnel-certs.sh"
elif [[ -n "${STUNNEL_TLS_EMAIL:-}" ]]; then
  bash "${SCRIPT_DIR}/install-certbot.sh"
else
  warn "Pas de cert Let's Encrypt — génération auto-signée (API : REDIS_TLS_REJECT_UNAUTHORIZED=false)"
  warn "Prod : STUNNEL_TLS_EMAIL=you@wise-eat.com ./install.sh certbot puis ./install.sh stunnel"
  openssl req -new -x509 -days 825 -nodes \
    -out /etc/stunnel/certs/fullchain.pem \
    -keyout /etc/stunnel/certs/privkey.pem \
    -subj "/CN=${STUNNEL_TLS_DOMAIN}"
  chown root:stunnel4 /etc/stunnel/certs/fullchain.pem /etc/stunnel/certs/privkey.pem
  chmod 644 /etc/stunnel/certs/fullchain.pem
  chmod 640 /etc/stunnel/certs/privkey.pem
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
    log "Mode A-lite (prod) — TLS Let's Encrypt + ACL Redis"
    ufw allow 6381/tcp comment 'Stunnel Redis cache TLS'
    ufw allow 6382/tcp comment 'Stunnel Redis bull TLS'
  fi
  ufw reload
else
  warn "ufw absent — configurer le pare-feu manuellement"
fi

log "Stunnel ${STUNNEL_MODE} — rediss://${STUNNEL_TLS_DOMAIN}:6381"
ss -tlnp | grep -E '6381|6382' || warn "Ports Stunnel non visibles"
systemctl status stunnel4 --no-pager || true

# Vérification TLS (si openssl dispo)
if command -v openssl >/dev/null 2>&1; then
  echo | openssl s_client -connect "127.0.0.1:6381" -servername "${STUNNEL_TLS_DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer 2>/dev/null || true
fi
