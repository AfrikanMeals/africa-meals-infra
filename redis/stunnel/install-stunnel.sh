#!/usr/bin/env bash
# Installe Stunnel Mode A sur le VPS (cache :6381, BullMQ :6382).
# Usage : sudo GCP_EGRESS_IP=203.0.113.50 bash install-stunnel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Exécuter en root : sudo GCP_EGRESS_IP=x.x.x.x bash $0" >&2
  exit 1
fi

if [[ -z "${GCP_EGRESS_IP}" ]]; then
  echo "Définir GCP_EGRESS_IP (IP egress statique Cloud Functions / Cloud NAT)." >&2
  exit 1
fi

apt update
apt install -y stunnel4 ufw

mkdir -p /etc/stunnel/conf.d

if [[ ! -f /etc/stunnel/redis.pem ]]; then
  openssl req -new -x509 -days 825 -nodes \
    -out /etc/stunnel/redis.pem -keyout /etc/stunnel/redis.pem \
    -subj "/CN=wise-eat.cloud"
  chmod 600 /etc/stunnel/redis.pem
fi

cp "${SCRIPT_DIR}/redis-cache.conf" /etc/stunnel/conf.d/
cp "${SCRIPT_DIR}/redis-bullmq.conf" /etc/stunnel/conf.d/

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

ufw deny 6381/tcp
ufw deny 6382/tcp
ufw allow from "${GCP_EGRESS_IP}" to any port 6381 proto tcp comment 'GCP CF Redis cache'
ufw allow from "${GCP_EGRESS_IP}" to any port 6382 proto tcp comment 'GCP CF Redis BullMQ'
ufw reload

echo "Stunnel actif. Vérifier : ss -tlnp | grep -E '6381|6382'"
systemctl status stunnel4 --no-pager || true
