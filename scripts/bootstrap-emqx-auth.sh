#!/usr/bin/env bash
# Bootstrap utilisateurs MQTT EMQX (built_in_database) via API REST.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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

emqx_auth_configured_via_docker_env() {
  docker ps --format '{{.Names}}' | grep -qx 'wise-eat-emqx-1' || return 1
  docker inspect wise-eat-emqx-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -q 'EMQX_AUTHENTICATION__1__BACKEND=built_in_database'
}

auth_chain_exists() {
  curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    "${EMQX_API}/authentication" 2>/dev/null \
    | grep -q 'built_in_database' || return 1
}

ensure_auth_chain() {
  if auth_chain_exists; then
    log "EMQX auth built_in_database déjà actif (API)"
    return 0
  fi
  if emqx_auth_configured_via_docker_env; then
    log "EMQX auth built_in_database via docker-compose (skip POST API)"
    return 0
  fi
  log "Activation auth built_in_database EMQX (API POST)"
  local code body
  body="$(curl -sS -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    -X POST "${EMQX_API}/authentication" \
    -H 'Content-Type: application/json' \
    -w '\n%{http_code}' \
    -d '{
      "mechanism": "password_based",
      "backend": "built_in_database",
      "user_id_type": "username",
      "password_hash_algorithm": {
        "name": "sha256",
        "salt_position": "suffix"
      }
    }')"
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    log "Auth chain créée via API"
    return 0
  fi
  if [[ "${code}" == "409" ]] || echo "${body}" | grep -qiE 'already|exist'; then
    log "Auth chain déjà présente (${code})"
    return 0
  fi
  warn "POST /authentication → HTTP ${code} : ${body}"
}

upsert_mqtt_user() {
  local user="$1" pass="$2"
  local create_payload update_payload code body

  create_payload="$(python3 -c 'import json,sys; print(json.dumps({"user_id":sys.argv[1],"password":sys.argv[2],"is_superuser":True}))' \
    "${user}" "${pass}")"
  update_payload="$(python3 -c 'import json,sys; print(json.dumps({"password":sys.argv[1],"is_superuser":True}))' \
    "${pass}")"

  if curl -sf -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    "${EMQX_API}/authentication/${AUTH_ID_ENC}/users/${user}" >/dev/null 2>&1; then
    body="$(curl -sS -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
      -X PUT "${EMQX_API}/authentication/${AUTH_ID_ENC}/users/${user}" \
      -H 'Content-Type: application/json' \
      -w '\n%{http_code}' \
      -d "${update_payload}")"
    code="${body##*$'\n'}"
    [[ "${code}" == "200" ]] || die "PUT user ${user} → HTTP ${code} : ${body%$'\n'*}"
    log "EMQX user mis à jour : ${user}"
    return 0
  fi

  body="$(curl -sS -u "${EMQX_DASHBOARD_USERNAME}:${EMQX_DASHBOARD_PASSWORD}" \
    -X POST "${EMQX_API}/authentication/${AUTH_ID_ENC}/users" \
    -H 'Content-Type: application/json' \
    -w '\n%{http_code}' \
    -d "${create_payload}")"
  code="${body##*$'\n'}"
  [[ "${code}" == "200" || "${code}" == "201" ]] || die "POST user ${user} → HTTP ${code} : ${body%$'\n'*}"
  log "EMQX user créé : ${user}"
}

log "Attente API EMQX (:${EMQX_DASHBOARD_PORT})…"
wait_for_emqx_api || die "API EMQX injoignable sur 127.0.0.1:${EMQX_DASHBOARD_PORT}"

ensure_auth_chain
upsert_mqtt_user "${MQTT_SUB_USER}" "${MQTT_BROKER_PASSWORD}"
upsert_mqtt_user "${MQTT_PUB_USER}" "${MQTT_ADMIN_PASSWORD}"

log "Utilisateurs MQTT EMQX prêts (${MQTT_SUB_USER}, ${MQTT_PUB_USER})"
