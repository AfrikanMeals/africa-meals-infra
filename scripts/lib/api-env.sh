#!/usr/bin/env bash
# Lecture sélective de /opt/wise-eat-api/.env.prod (sans source bash complet).
set -euo pipefail

# shellcheck source=env-file-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env-file-sanitize.sh"

API_ENV_FILE="${API_ENV_FILE:-${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}}"
API_ENV_DIR="${API_ENV_DIR:-$(dirname "${API_ENV_FILE}")}"

api_env_strip_quotes() {
  env_file_sanitize_value "$1"
}

api_env_var() {
  local key="$1"
  local line val
  [[ -f "${API_ENV_FILE}" ]] || return 1
  line="$(grep -E "^${key}=" "${API_ENV_FILE}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 1
  val="${line#*=}"
  api_env_strip_quotes "${val}"
}

api_env_first_set() {
  local key val
  for key in "$@"; do
    val="$(api_env_var "${key}" 2>/dev/null || true)"
    if [[ -n "${val}" ]]; then
      echo "${val}"
      return 0
    fi
  done
  return 1
}

api_env_resolve_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 1
  if [[ "${path}" == /* ]]; then
    echo "${path}"
  else
    echo "${API_ENV_DIR}/${path}"
  fi
}
