#!/usr/bin/env bash
# Chemins API — monorepo local (africa-meals-api) ou VPS (/opt/wise-eat-api).
set -euo pipefail

api_paths_init() {
  API_PATHS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  API_PATHS_K8S_DIR="$(cd "${API_PATHS_SCRIPT_DIR}/.." && pwd)"
  API_PATHS_INFRA_ROOT="$(cd "${API_PATHS_K8S_DIR}/.." && pwd)"
  API_PATHS_MONO_ROOT="$(cd "${API_PATHS_INFRA_ROOT}/.." && pwd)"
}

api_resolve_source_dir() {
  api_paths_init

  if [[ -n "${API_SOURCE_DIR:-}" && -f "${API_SOURCE_DIR}/package.json" ]]; then
    printf '%s\n' "${API_SOURCE_DIR}"
    return 0
  fi

  local candidate dir
  for candidate in \
    "${API_PATHS_MONO_ROOT}/africa-meals-api" \
    "${API_PATHS_MONO_ROOT}/wise-eat-api" \
    "/opt/wise-eat-api" \
    "/opt/africa-meals-api"; do
    if [[ -f "${candidate}/package.json" ]]; then
      printf '%s\n' "$(cd "${candidate}" && pwd)"
      return 0
    fi
  done

  for dir in "${API_PATHS_MONO_ROOT}" "/opt"; do
    [[ -d "${dir}" ]] || continue
    for candidate in "${dir}"/*-api; do
      [[ -f "${candidate}/package.json" ]] || continue
      printf '%s\n' "$(cd "${candidate}" && pwd)"
      return 0
    done
  done

  return 1
}

api_resolve_packages_dir() {
  api_paths_init
  local api_dir="${1:-}"
  local candidate

  for candidate in \
    "${API_PATHS_MONO_ROOT}/packages" \
    "${API_PATHS_MONO_ROOT}/africa-meals-project/packages" \
    "${api_dir}/../packages" \
    "${api_dir}/../africa-meals-project/packages" \
    "/opt/packages" \
    "/opt/wise-eat-project/packages" \
    "/opt/africa-meals-project/packages"; do
    if [[ -f "${candidate}/africa-meals-proto/package.json" ]]; then
      printf '%s\n' "$(cd "${candidate}" && pwd)"
      return 0
    fi
  done

  return 1
}

api_prepare_docker_context() {
  api_paths_init
  local api_dir packages_dir ctx

  api_dir="$(api_resolve_source_dir)" || return 1
  packages_dir="$(api_resolve_packages_dir "${api_dir}")" || return 1

  if [[ "${api_dir}" == "${API_PATHS_MONO_ROOT}/africa-meals-api" && -d "${API_PATHS_MONO_ROOT}/packages" ]]; then
    printf '%s\n' "${API_PATHS_MONO_ROOT}"
    return 0
  fi

  if [[ -d "${API_PATHS_MONO_ROOT}/africa-meals-project/packages" && "${api_dir}" == "${API_PATHS_MONO_ROOT}/africa-meals-api" ]]; then
    printf '%s\n' "${API_PATHS_MONO_ROOT}"
    return 0
  fi

  ctx="$(mktemp -d)"
  mkdir -p "${ctx}/africa-meals-api" "${ctx}/packages/africa-meals-field-selection" "${ctx}/packages/africa-meals-proto"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude node_modules \
      --exclude dist \
      --exclude .git \
      "${api_dir}/" "${ctx}/africa-meals-api/"
    rsync -a \
      "${packages_dir}/africa-meals-field-selection/" "${ctx}/packages/africa-meals-field-selection/"
    rsync -a \
      "${packages_dir}/africa-meals-proto/" "${ctx}/packages/africa-meals-proto/"
  else
    tar -C "${api_dir}" \
      --exclude=node_modules --exclude=dist --exclude=.git \
      -cf - . | tar -C "${ctx}/africa-meals-api" -xf -
    tar -C "${packages_dir}/africa-meals-field-selection" -cf - . \
      | tar -C "${ctx}/packages/africa-meals-field-selection" -xf -
    tar -C "${packages_dir}/africa-meals-proto" -cf - . \
      | tar -C "${ctx}/packages/africa-meals-proto" -xf -
  fi

  printf '%s\n' "${ctx}"
}

api_resolve_env_file() {
  api_paths_init
  local explicit="${1:-}"
  local api_dir candidate
  local -a tried=()

  if [[ -n "${explicit}" ]]; then
    if [[ -f "${explicit}" ]]; then
      printf '%s\n' "$(cd "$(dirname "${explicit}")" && pwd)/$(basename "${explicit}")"
      return 0
    fi
    tried+=("${explicit}")
  fi

  api_dir="$(api_resolve_source_dir 2>/dev/null || true)"

  local -a bases=()
  [[ -n "${api_dir}" ]] && bases+=("$(dirname "${api_dir}")")
  bases+=("${PWD}" "${API_PATHS_MONO_ROOT}" "/opt")

  local base api env_name
  for base in "${bases[@]}"; do
    [[ -n "${base}" && -d "${base}" ]] || continue
    for api in wise-eat-api africa-meals-api; do
      for env_name in .env.prod .env.production .env; do
        candidate="${base}/${api}/${env_name}"
        if [[ -f "${candidate}" ]]; then
          printf '%s\n' "$(cd "$(dirname "${candidate}")" && pwd)/$(basename "${candidate}")"
          return 0
        fi
        tried+=("${candidate}")
      done
    done
  done

  if [[ ${#tried[@]} -gt 0 ]]; then
    printf '%s\n' "${tried[@]}" >&2
  fi
  return 1
}

api_env_file_usage_hint() {
  cat <<EOF
Fichier .env introuvable.

Sur le VPS Wise Eat (dépôts séparés) :
  sudo ${API_PATHS_SCRIPT_DIR:-./}/deploy-api-production.sh /opt/wise-eat-api/.env.prod

Monorepo local :
  sudo infra/k8s/scripts/deploy-api-production.sh africa-meals-api/.env.prod

Chemins testés (derniers essais sur stderr).
EOF
}
