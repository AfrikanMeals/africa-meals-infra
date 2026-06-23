#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
GCP_EGRESS_IP="${GCP_EGRESS_IP:-}"
STUNNEL_AUTH_ONLY="${STUNNEL_AUTH_ONLY:-}"

if [[ -z "${GCP_EGRESS_IP}" && "${STUNNEL_AUTH_ONLY}" != "1" ]]; then
  cat >&2 <<'EOF'
Stunnel Mode A — choisir une option :

  A) Strict (pare-feu IP) — Cloud NAT + IP statique GCP (~30–45 €/mois)
     sudo GCP_EGRESS_IP=x.x.x.x ./install.sh stunnel

  B) Auth-only (sans Cloud NAT, ~0 €) — TLS Stunnel + mot de passe Redis ACL
     sudo STUNNEL_AUTH_ONLY=1 ./install.sh stunnel

Un domaine vers Cloud Functions (api.wise-eat.com) ne remplace PAS l’IP egress :
l’API sort vers wise-eat.cloud:6381 avec une IP Google variable — UFW filtre
la source IP, pas le domaine de l’API.

Voir docs/REDIS_VPS_PRODUCTION.md § Mode A — coût.
EOF
  exit 1
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
  if [[ -n "${GCP_EGRESS_IP}" ]]; then
    log "UFW strict — autoriser ${GCP_EGRESS_IP} uniquement"
    ufw deny 6381/tcp 2>/dev/null || true
    ufw deny 6382/tcp 2>/dev/null || true
    ufw allow from "${GCP_EGRESS_IP}" to any port 6381 proto tcp comment 'GCP CF Redis cache'
    ufw allow from "${GCP_EGRESS_IP}" to any port 6382 proto tcp comment 'GCP CF Redis BullMQ'
  else
    warn "Mode A-lite (STUNNEL_AUTH_ONLY) — :6381/:6382 ouverts (TLS + ACL Redis)"
    warn "Exiger mots de passe forts + monitoring Grafana ; envisager fail2ban"
    ufw allow 6381/tcp comment 'Stunnel Redis cache auth-only'
    ufw allow 6382/tcp comment 'Stunnel Redis bull auth-only'
  fi
  ufw reload
else
  warn "ufw absent — configurer le pare-feu manuellement"
fi

log "Stunnel actif — API : rediss://wise-eat-cache:***@wise-eat.cloud:6381"
ss -tlnp | grep -E '6381|6382' || warn "Ports Stunnel non visibles"
systemctl status stunnel4 --no-pager || true
