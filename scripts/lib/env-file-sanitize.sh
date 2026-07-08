#!/usr/bin/env bash
# Normalise les valeurs .env (guillemets, espaces, CRLF) — aligné sur dotenv NestJS local.
set -euo pipefail

env_file_sanitize_value() {
  local v="$1"
  v="${v//$'\r'/}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "${#v}" -ge 2 ]]; then
    if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
      v="${v:1:${#v}-2}"
    elif [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
      v="${v:1:${#v}-2}"
    fi
  fi
  echo "${v}"
}

env_file_sanitize_line() {
  local line="$1"
  local key val
  [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
  key="${BASH_REMATCH[1]}"
  val="$(env_file_sanitize_value "${BASH_REMATCH[2]}")"
  printf '%s=%s\n' "${key}" "${val}"
}

env_file_sanitize_file() {
  local in_file="$1"
  local out_file="$2"
  local line
  : > "${out_file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    if sanitized="$(env_file_sanitize_line "${line}" 2>/dev/null)"; then
      echo "${sanitized}" >> "${out_file}"
    fi
  done < "${in_file}"
}
