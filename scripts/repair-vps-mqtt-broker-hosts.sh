#!/usr/bin/env bash
# Résout le hairpin NAT sur le VPS : PM2 joint broker.wise-eat.com via loopback
# (nginx stream MQTTS sur 127.0.0.1:8883) tout en gardant le nom de domaine dans les apps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BROKER_DOMAIN="${EMQX_BROKER_DOMAIN:-broker.wise-eat.com}"
HOSTS_LINE="127.0.0.1 ${BROKER_DOMAIN}"
HOSTS_FILE="/etc/hosts"
MARKER="# wise-eat-emqx-broker-local"

require_root

if grep -qF "${MARKER}" "${HOSTS_FILE}" 2>/dev/null; then
  log "Entrée ${BROKER_DOMAIN} déjà présente dans ${HOSTS_FILE}"
else
  log "Ajout ${HOSTS_LINE} dans ${HOSTS_FILE} (${MARKER})"
  echo "${HOSTS_LINE} ${MARKER}" >> "${HOSTS_FILE}"
  log "Entrée hosts ajoutée"
fi

log "Test MQTTS local via domaine"
if command -v mosquitto_sub >/dev/null 2>&1 && [[ -f "${EMQX_ENV}" ]]; then
  set -a && source "${EMQX_ENV}" && set +a
  if mosquitto_sub \
    -L "mqtts://wise-eat-mqtt:${MQTT_BROKER_PASSWORD}@${BROKER_DOMAIN}:8883/wiseeat/internal/ws/test" \
    -W 3 -d 2>&1 | grep -q 'CONNACK (0)'; then
    log "mosquitto_sub MQTTS OK depuis le VPS"
  else
    warn "mosquitto_sub n'a pas confirmé CONNACK — vérifier nginx stream / EMQX"
  fi
else
  warn "mosquitto_sub ou ${EMQX_ENV} absent — test MQTT ignoré"
fi

log "Terminé. Redémarrer PM2 : pm2 restart africa-meals-api africa-meals-ws --update-env"
