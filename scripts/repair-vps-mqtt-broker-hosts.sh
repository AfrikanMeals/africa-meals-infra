#!/usr/bin/env bash
# Résout le hairpin NAT sur le VPS : PM2 joint broker.wise-eat.com via loopback
# (nginx stream MQTTS sur 127.0.0.1:8883 / [::1]:8883) tout en gardant le domaine dans les apps.
# Avec AAAA DNS, les clients préfèrent IPv6 — ::1 est requis en plus de 127.0.0.1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BROKER_DOMAIN="${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}"
HOSTS_FILE="/etc/hosts"
MARKER="# wise-eat-emqx-broker-local"
MARKER_V6="# wise-eat-emqx-broker-local-v6"

require_root

remove_hosts_marker_lines() {
  local tmp
  tmp="$(mktemp)"
  grep -vF "${MARKER}" "${HOSTS_FILE}" | grep -vF "${MARKER_V6}" > "${tmp}" || true
  cat "${tmp}" > "${HOSTS_FILE}"
  rm -f "${tmp}"
}

remove_hosts_marker_lines
log "Ajout loopback v4 + v6 pour ${BROKER_DOMAIN} dans ${HOSTS_FILE}"
{
  echo "127.0.0.1 ${BROKER_DOMAIN} ${MARKER}"
  echo "::1 ${BROKER_DOMAIN} ${MARKER_V6}"
} >> "${HOSTS_FILE}"

log "Test MQTTS local via domaine"
if command -v mosquitto_sub >/dev/null 2>&1 && [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
  if mosquitto_sub \
    -L "mqtts://wise-eat-mqtt:${MQTT_BROKER_PASSWORD}@${BROKER_DOMAIN}:8883/wiseeat/internal/ws/test" \
    -W 3 -d 2>&1 | grep -q 'CONNACK (0)'; then
    log "mosquitto_sub MQTTS OK depuis le VPS"
  else
    warn "mosquitto_sub n'a pas confirmé CONNACK — vérifier nginx stream / EMQX / UFW :8883"
  fi
else
  warn "mosquitto_sub ou ${EMQX_ENV} absent — test MQTT ignoré"
fi

log "Terminé. Redémarrer PM2 : pm2 restart africa-meals-api africa-meals-ws --update-env"
