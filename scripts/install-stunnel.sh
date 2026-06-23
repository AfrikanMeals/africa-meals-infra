#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"
[[ -n "${GCP_EGRESS_IP}" ]] || die "Définir GCP_EGRESS_IP (IP egress Cloud Functions / Cloud NAT)"

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
  ufw deny 6381/tcp 2>/dev/null || true
  ufw deny 6382/tcp 2>/dev/null || true
  ufw allow from "${GCP_EGRESS_IP}" to any port 6381 proto tcp comment 'GCP CF Redis cache'
  ufw allow from "${GCP_EGRESS_IP}" to any port 6382 proto tcp comment 'GCP CF Redis BullMQ'
  ufw reload
else
  warn "ufw absent — configurer le pare-feu manuellement pour :6381 / :6382"
fi

log "Stunnel actif — ss -tlnp | grep -E '6381|6382'"
ss -tlnp | grep -E '6381|6382' || warn "Ports Stunnel non visibles"
systemctl status stunnel4 --no-pager || true
