#!/usr/bin/env bash
# Helpers API EMQX 5.x — auth Bearer via POST /api/v5/login (basic dashboard interdit).
set -euo pipefail

EMQX_API_TOKEN=""

emqx_api_login() {
  local resp code body token
  [[ -n "${EMQX_DASHBOARD_PASSWORD:-}" ]] || die "EMQX_DASHBOARD_PASSWORD requis"

  body="$(python3 -c 'import json,os; print(json.dumps({"username":os.environ["EMQX_DASHBOARD_USERNAME"],"password":os.environ["EMQX_DASHBOARD_PASSWORD"]}))' \
    EMQX_DASHBOARD_USERNAME="${EMQX_DASHBOARD_USERNAME:-admin}" \
    EMQX_DASHBOARD_PASSWORD="${EMQX_DASHBOARD_PASSWORD}")"

  resp="$(curl -sS -X POST "${EMQX_API}/login" \
    -H 'Content-Type: application/json' \
    -w '\n%{http_code}' \
    -d "${body}")"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "${code}" != "200" && "${code}" != "201" ]]; then
    die "POST /login → HTTP ${code} : ${body} (vérifier EMQX_DASHBOARD_PASSWORD dans .env.emqx)"
  fi

  token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<< "${body}")"
  [[ -n "${token}" ]] || die "Token API EMQX absent dans la réponse /login"
  EMQX_API_TOKEN="${token}"
}

wait_for_emqx_api_login() {
  local max="${1:-90}" i
  for ((i = 1; i <= max; i++)); do
    if curl -sf "${EMQX_API}/status" >/dev/null 2>&1; then
      if emqx_api_login 2>/dev/null; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

emqx_api() {
  [[ -n "${EMQX_API_TOKEN}" ]] || emqx_api_login
  curl -fsS -H "Authorization: Bearer ${EMQX_API_TOKEN}" "$@"
}

emqx_api_code() {
  [[ -n "${EMQX_API_TOKEN}" ]] || emqx_api_login
  curl -sS -H "Authorization: Bearer ${EMQX_API_TOKEN}" "$@"
}
