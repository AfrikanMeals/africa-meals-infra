#!/usr/bin/env bash
# Bootstrap utilisateurs MQTT EMQX (built_in_database) via API REST.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

EMQX_ENV="${EMQX_ENV:-${EMQX_DIR}/.env.emqx}"
EMQX_DASHBOARD_PORT="${EMQX_DASHBOARD_PORT:-18083}"
EMQX_API="http://127.0.0.1:${EMQX_DASHBOARD_PORT}/api/v5"

[[ -f "${EMQX_ENV}" ]] || die ".env.emqx introuvable — lancer ./install.sh emqx"

set -a && source "${EMQX_ENV}" && set +a

EMQX_DASHBOARD_USERNAME="${EMQX_DASHBOARD_USERNAME:-admin}"
MQTT_SUB_USER="${MQTT_SUB_USERNAME:-wise-eat-mqtt}"
MQTT_PUB_USER="${MQTT_PUB_USERNAME:-wise-eat-admin}"

wait_for_emqx_api() {
  local max="${1:-90}"
  for _ in $(seq 1 "$max"); do
    if curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
      "${EMQX_API}/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

auth_chain_exists() {
  curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    "${EMQX_API}/authentication" 2>/dev/null \
    | grep -q 'built_in_database' || return 1
}

ensure_auth_chain() {
  if auth_chain_exists; then
    log "EMQX auth built_in_database déjà actif"
    return 0
  fi
  log "Activation auth built_in_database EMQX"
  curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    -X POST "${EMQX_API}/authentication" \
    -H 'Content-Type: application/json' \
    -d '{
      "mechanism": "password_based",
      "backend": "built_in_database",
      "user_id_type": "username",
      "password_hash_algorithm": {
        "name": "sha256",
        "salt_position": "suffix"
      }
    }' >/dev/null
}

upsert_mqtt_user() {
  local user="$1" pass="$2"
  local auth_id='password_based:built_in_database'
  local encoded
  encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${auth_id}")"

  if curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    "${EMQX_API}/authentication/${encoded}/users/${user}" >/dev/null 2>&1; then
    curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
      -X PUT "${EMQX_API}/authentication/${encoded}/users/${user}" \
      -H 'Content-Type: application/json' \
      -d "{\"password\":\"${pass}\"}" >/dev/null
    log "EMQX user mis à jour : ${user}"
  else
    curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
      -X POST "${EMQX_API}/authentication/${encoded}/users" \
      -H 'Content-Type: application/json' \
      -d "{\"user_id\":\"${user}\",\"password\":\"${pass}\"}" >/dev/null
    log "EMQX user créé : ${user}"
  fi
}

log "Attente API EMQX (:${EMQX_DASHBOARD_PORT})…"
wait_for_emqx_api || die "API EMQX injoignable sur 127.0.0.1:${EMQX_DASHBOARD_PORT}"

ensure_auth_chain
upsert_mqtt_user "${MQTT_SUB_USER}" "${MQTT_BROKER_PASSWORD}"
upsert_mqtt_user "${MQTT_PUB_USER}" "${MQTT_ADMIN_PASSWORD}"

log "Utilisateurs MQTT EMQX prêts (${MQTT_SUB_USER}, ${MQTT_PUB_USER})"
