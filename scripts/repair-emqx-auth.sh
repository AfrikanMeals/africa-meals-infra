#!/usr/bin/env bash
# Répare utilisateurs MQTT EMQX + règles ACL + test local (mosquitto).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

EMQX_ENV="${EMQX_ENV:-${EMQX_DIR}/.env.emqx}"
EMQX_DASHBOARD_PORT="${EMQX_DASHBOARD_PORT:-18083}"
EMQX_API="http://127.0.0.1:${EMQX_DASHBOARD_PORT}/api/v5"
AUTH_ID='password_based:built_in_database'
AUTH_ID_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${AUTH_ID}")"

[[ -f "${EMQX_ENV}" ]] || die ".env.emqx introuvable — lancer ./install.sh emqx"
set -a && source "${EMQX_ENV}" && set +a

EMQX_DASHBOARD_USERNAME="${EMQX_DASHBOARD_USERNAME:-admin}"
MQTT_SUB_USER="${MQTT_SUB_USERNAME:-wise-eat-mqtt}"
MQTT_PUB_USER="${MQTT_PUB_USERNAME:-wise-eat-admin}"
MQTT_SUB_PASS="${MQTT_BROKER_PASSWORD:?MQTT_BROKER_PASSWORD requis dans .env.emqx}"
MQTT_PUB_PASS="${MQTT_ADMIN_PASSWORD:?MQTT_ADMIN_PASSWORD requis dans .env.emqx}"

emqx_api() {
  curl -fsS -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" "$@"
}

log "=== Repair EMQX MQTT auth ==="

if ! nc -z 127.0.0.1 "${EMQX_DASHBOARD_PORT}" 2>/dev/null; then
  die "Dashboard EMQX injoignable sur 127.0.0.1:${EMQX_DASHBOARD_PORT}"
fi

log "Chaînes d'authentification :"
emqx_api "${EMQX_API}/authentication" 2>/dev/null \
  | python3 -m json.tool 2>/dev/null | sed 's/^/[wise-eat]      /' || true

log "Utilisateurs avant repair :"
emqx_api "${EMQX_API}/authentication/${AUTH_ID_ENC}/users?limit=100" 2>/dev/null \
  | python3 -m json.tool 2>/dev/null | sed 's/^/[wise-eat]      /' || warn "Aucun user listé (chaîne absente ?)"

ensure_authz_allow_user() {
  local user="$1"
  local payload
  payload="$(python3 - <<PY
import json
print(json.dumps({
  "username": "${user}",
  "rules": [
    {"topic": "#", "permission": "allow", "action": "all"}
  ]
}))
PY
)"
  if emqx_api -X POST "${EMQX_API}/authorization/sources/built_in_database/rules/username" \
    -H 'Content-Type: application/json' \
    -d "${payload}" >/dev/null 2>&1; then
    log "ACL allow # pour ${user}"
  else
    emqx_api -X PUT "${EMQX_API}/authorization/sources/built_in_database/rules/username/${user}" \
      -H 'Content-Type: application/json' \
      -d "{\"rules\":[{\"topic\":\"#\",\"permission\":\"allow\",\"action\":\"all\"}]}" >/dev/null 2>&1 \
      && log "ACL allow # pour ${user} (PUT)" \
      || warn "ACL ${user} — configurer manuellement si publish/subscribe refusés"
  fi
}

bash "${SCRIPT_DIR}/bootstrap-emqx-auth.sh"
ensure_authz_allow_user "${MQTT_SUB_USER}"
ensure_authz_allow_user "${MQTT_PUB_USER}"

emqx_api -X DELETE "${EMQX_API}/authorization/cache" >/dev/null 2>&1 || true

log "Test MQTT local (plain)…"
apt install -y mosquitto-clients 2>/dev/null || true

test_mqtt_auth() {
  local user="$1" pass="$2"
  local err rc=0
  err="$(timeout 4 mosquitto_sub -h 127.0.0.1 -p 1883 -u "${user}" -P "${pass}" \
    -t 'wiseeat/repair-test' -C 1 2>&1)" || rc=$?
  if echo "${err}" | grep -qiE 'not authorised|bad user name|bad password|connection refused'; then
    warn "FAIL ${user} @ 127.0.0.1:1883 — ${err}"
    return 1
  fi
  log "OK  ${user} @ 127.0.0.1:1883 (auth acceptée)"
  return 0
}

test_mqtt_auth "${MQTT_PUB_USER}" "${MQTT_PUB_PASS}" || \
  warn "Voir : docker logs --tail=40 wise-eat-emqx-1 | grep -i auth"
test_mqtt_auth "${MQTT_SUB_USER}" "${MQTT_SUB_PASS}" || true

cat <<EOF

--- Config apps (MQTTS / WSS public) ---

africa-meals-api/.env :
  MQTT_BROKER_HOST=broker.wise-eat.com
  MQTT_BROKER_PORT=8883
  MQTT_BROKER_WS_PORT=8884
  MQTT_BROKER_PROTOCOL=mqtts
  MQTT_BROKER_URL=mqtts://broker.wise-eat.com:8883
  MQTT_BROKER_WS_URL=wss://broker.wise-eat.com:8884/mqtt
  MQTT_BROKER_USERNAME=${MQTT_PUB_USER}
  MQTT_BROKER_PASSWORD=${MQTT_PUB_PASS}

africa-meals-ws/.env :
  MQTT_BROKER_HOST=broker.wise-eat.com
  MQTT_BROKER_PORT=8883
  MQTT_BROKER_WS_PORT=8884
  MQTT_BROKER_PROTOCOL=mqtts
  MQTT_BROKER_URL=mqtts://broker.wise-eat.com:8883
  MQTT_BROKER_WS_URL=wss://broker.wise-eat.com:8884/mqtt
  MQTT_BROKER_USERNAME=${MQTT_SUB_USER}
  MQTT_BROKER_PASSWORD=${MQTT_SUB_PASS}

Prérequis TLS : sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh emqx-broker
Puis : pm2 restart africa-meals-api africa-meals-ws
EOF
