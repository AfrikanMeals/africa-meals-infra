#!/usr/bin/env bash
# Chemins WS — monorepo local (africa-meals-ws) ou VPS (/opt/wise-eat + /opt/wise-eat-ws).
set -euo pipefail

ws_paths_init() {
  WS_PATHS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  WS_PATHS_K8S_DIR="$(cd "${WS_PATHS_SCRIPT_DIR}/.." && pwd)"
  WS_PATHS_INFRA_ROOT="$(cd "${WS_PATHS_K8S_DIR}/.." && pwd)"
  WS_PATHS_MONO_ROOT="$(cd "${WS_PATHS_INFRA_ROOT}/.." && pwd)"
}

# Répertoire source Nest (package.json) — africa-meals-ws ou wise-eat-ws.
ws_resolve_source_dir() {
  ws_paths_init

  if [[ -n "${WS_SOURCE_DIR:-}" && -f "${WS_SOURCE_DIR}/package.json" ]]; then
    printf '%s\n' "${WS_SOURCE_DIR}"
    return 0
  fi

  local candidate dir
  for candidate in \
    "${WS_PATHS_MONO_ROOT}/africa-meals-ws" \
    "${WS_PATHS_MONO_ROOT}/wise-eat-ws" \
    "/opt/wise-eat-ws" \
    "/opt/africa-meals-ws"; do
    if [[ -f "${candidate}/package.json" ]]; then
      printf '%s\n' "$(cd "${candidate}" && pwd)"
      return 0
    fi
  done

  for dir in "${WS_PATHS_MONO_ROOT}" "/opt"; do
    [[ -d "${dir}" ]] || continue
    for candidate in "${dir}"/*-ws; do
      [[ -f "${candidate}/package.json" ]] || continue
      printf '%s\n' "$(cd "${candidate}" && pwd)"
      return 0
    done
  done

  return 1
}

# packages/ requis par Dockerfile.africa-meals-ws
ws_resolve_packages_dir() {
  ws_paths_init
  local ws_dir="${1:-}"
  local candidate

  for candidate in \
    "${WS_PATHS_MONO_ROOT}/packages" \
    "${ws_dir}/../packages" \
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

# Contexte Docker : monorepo natif ou copie réelle (VPS — Docker ne suit pas les symlinks hors contexte).
ws_prepare_docker_context() {
  ws_paths_init
  local ws_dir packages_dir ctx

  ws_dir="$(ws_resolve_source_dir)" || return 1
  packages_dir="$(ws_resolve_packages_dir "${ws_dir}")" || return 1

  if [[ "${ws_dir}" == "${WS_PATHS_MONO_ROOT}/africa-meals-ws" && -d "${WS_PATHS_MONO_ROOT}/packages" ]]; then
    printf '%s\n' "${WS_PATHS_MONO_ROOT}"
    return 0
  fi

  ctx="$(mktemp -d)"
  mkdir -p "${ctx}/africa-meals-ws" "${ctx}/packages/africa-meals-field-selection" "${ctx}/packages/africa-meals-proto"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude node_modules \
      --exclude dist \
      --exclude .git \
      "${ws_dir}/" "${ctx}/africa-meals-ws/"
    rsync -a \
      "${packages_dir}/africa-meals-field-selection/" "${ctx}/packages/africa-meals-field-selection/"
    rsync -a \
      "${packages_dir}/africa-meals-proto/" "${ctx}/packages/africa-meals-proto/"
  else
    tar -C "${ws_dir}" \
      --exclude=node_modules --exclude=dist --exclude=.git \
      -cf - . | tar -C "${ctx}/africa-meals-ws" -xf -
    tar -C "${packages_dir}/africa-meals-field-selection" -cf - . \
      | tar -C "${ctx}/packages/africa-meals-field-selection" -xf -
    tar -C "${packages_dir}/africa-meals-proto" -cf - . \
      | tar -C "${ctx}/packages/africa-meals-proto" -xf -
  fi

  printf '%s\n' "${ctx}"
}

# Fichier .env — argument explicite ou auto-détection VPS/monorepo.
ws_resolve_env_file() {
  ws_paths_init
  local explicit="${1:-}"
  local ws_dir candidate
  local -a tried=()

  if [[ -n "${explicit}" ]]; then
    if [[ -f "${explicit}" ]]; then
      printf '%s\n' "$(cd "$(dirname "${explicit}")" && pwd)/$(basename "${explicit}")"
      return 0
    fi
    tried+=("${explicit}")
  fi

  ws_dir="$(ws_resolve_source_dir 2>/dev/null || true)"

  local -a bases=()
  [[ -n "${ws_dir}" ]] && bases+=("$(dirname "${ws_dir}")")
  bases+=("${PWD}" "${WS_PATHS_MONO_ROOT}" "/opt")

  local base ws env_name
  for base in "${bases[@]}"; do
    [[ -n "${base}" && -d "${base}" ]] || continue
    for ws in wise-eat-ws africa-meals-ws; do
      for env_name in .env.prod .env.production .env; do
        candidate="${base}/${ws}/${env_name}"
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

ws_env_file_usage_hint() {
  cat <<EOF
Fichier .env introuvable.

Sur le VPS Wise Eat (dépôts séparés) :
  sudo ${WS_PATHS_SCRIPT_DIR:-./}/deploy-ws-production.sh /opt/wise-eat-ws/.env.prod

Monorepo local :
  sudo infra/k8s/scripts/deploy-ws-production.sh africa-meals-ws/.env.prod

Chemins testés (derniers essais sur stderr).
EOF
}
