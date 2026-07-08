#!/usr/bin/env bash
# Helpers — sauvegarde MongoDB off-site (GCS, Firebase Storage, AWS S3).
# Rotation mensuelle : Backup_DB_1 … Backup_DB_4 (écrasement du même slot chaque mois).
set -euo pipefail

MONGODB_CLOUD_LAST_ERROR=""

mongodb_cloud_backup_week_slot() {
  local day
  day="$(date +%d)"
  day=$((10#${day}))
  if (( day <= 7 )); then
    echo 1
  elif (( day <= 14 )); then
    echo 2
  elif (( day <= 21 )); then
    echo 3
  else
    echo 4
  fi
}

mongodb_cloud_backup_week_slot_for_day() {
  local day="$1"
  day=$((10#${day}))
  if (( day <= 7 )); then
    echo 1
  elif (( day <= 14 )); then
    echo 2
  elif (( day <= 21 )); then
    echo 3
  else
    echo 4
  fi
}

mongodb_cloud_backup_object_name() {
  local slot="$1"
  local prefix="${MONGO_CLOUD_BACKUP_PREFIX:-Backup_DB_}"
  local ext="${MONGO_CLOUD_BACKUP_ARCHIVE_EXT:-.tar.gz}"
  echo "${prefix}${slot}${ext}"
}

mongodb_cloud_backup_resolve_source_dir() {
  local backup_dir="$1"
  local stamp
  stamp="$(date +%Y-%m-%d)"
  local snapshot="${backup_dir}/snapshots/${stamp}"
  local latest="${backup_dir}/latest"

  if [[ -d "${snapshot}" ]] && [[ -n "$(ls -A "${snapshot}" 2>/dev/null || true)" ]]; then
    echo "${snapshot}"
    return 0
  fi
  if [[ -d "${latest}" ]] && [[ -n "$(ls -A "${latest}" 2>/dev/null || true)" ]]; then
    echo "${latest}"
    return 0
  fi
  return 1
}

mongodb_cloud_backup_create_archive() {
  local source_dir="$1"
  local archive_path="$2"
  local tmp_dir parent base

  parent="$(dirname "${archive_path}")"
  base="$(basename "${archive_path}")"
  mkdir -p "${parent}"

  tmp_dir="$(mktemp -d "${parent}/.pack-XXXXXX")"
  tar -czf "${tmp_dir}/${base}" -C "${source_dir}" .
  mv "${tmp_dir}/${base}" "${archive_path}"
  rmdir "${tmp_dir}" 2>/dev/null || rm -rf "${tmp_dir}"
}

mongodb_cloud_backup_uri_join() {
  local base="$1"
  local object="$2"
  base="${base%/}"
  echo "${base}/${object}"
}

mongodb_cloud_backup_has_gs_cli() {
  command -v gcloud >/dev/null 2>&1 || command -v gsutil >/dev/null 2>&1
}

mongodb_cloud_backup_gs_cli_hint() {
  echo "Installer : sudo ./install.sh mongodb-cloud-tools"
  echo "  ou : sudo apt install -y google-cloud-cli  (ou snap install google-cloud-cli --classic)"
}

mongodb_cloud_backup_aws_cli_hint() {
  echo "Installer : sudo ./install.sh mongodb-cloud-tools"
  echo "  ou : sudo apt install -y awscli"
}

mongodb_cloud_backup_run_gs_upload() {
  local uri="$1"
  local archive="$2"
  local credentials="${3:-}"
  local err_file rc

  MONGODB_CLOUD_LAST_ERROR=""

  if ! mongodb_cloud_backup_has_gs_cli; then
    MONGODB_CLOUD_LAST_ERROR="gcloud/gsutil introuvable sur le PATH. $(mongodb_cloud_backup_gs_cli_hint)"
    return 2
  fi

  if [[ -n "${credentials}" ]]; then
    if [[ ! -f "${credentials}" ]]; then
      MONGODB_CLOUD_LAST_ERROR="Fichier credentials absent ou illisible : ${credentials}"
      return 3
    fi
    if [[ ! -r "${credentials}" ]]; then
      MONGODB_CLOUD_LAST_ERROR="Credentials non lisibles (chmod 600 recommandé) : ${credentials}"
      return 3
    fi
    export GOOGLE_APPLICATION_CREDENTIALS="${credentials}"
  elif [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    MONGODB_CLOUD_LAST_ERROR="Aucun compte de service Google (GOOGLE_APPLICATION_CREDENTIALS / accounts.json)"
    return 3
  fi

  err_file="$(mktemp)"
  if command -v gcloud >/dev/null 2>&1; then
    if gcloud storage cp --quiet "${archive}" "${uri}" 2>"${err_file}"; then
      rm -f "${err_file}"
      return 0
    fi
    rc=$?
  elif command -v gsutil >/dev/null 2>&1; then
    if gsutil -q cp "${archive}" "${uri}" 2>"${err_file}"; then
      rm -f "${err_file}"
      return 0
    fi
    rc=$?
  else
    rc=2
  fi

  MONGODB_CLOUD_LAST_ERROR="$(tr '\n' ' ' < "${err_file}" | sed 's/  */ /g' | cut -c1-500)"
  rm -f "${err_file}"
  if [[ -z "${MONGODB_CLOUD_LAST_ERROR}" ]]; then
    MONGODB_CLOUD_LAST_ERROR="gcloud/gsutil exit ${rc} (sans message — vérifier IAM Storage Object Admin sur le bucket)"
  fi
  return 1
}

mongodb_cloud_backup_run_aws_upload() {
  local uri="$1"
  local archive="$2"
  local region="${3:-}"
  local err_file rc aws_cmd

  MONGODB_CLOUD_LAST_ERROR=""

  if ! command -v aws >/dev/null 2>&1; then
    MONGODB_CLOUD_LAST_ERROR="aws CLI introuvable. $(mongodb_cloud_backup_aws_cli_hint)"
    return 2
  fi

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && [[ -z "${AWS_PROFILE:-}" ]] && [[ ! -f "${HOME}/.aws/credentials" ]]; then
    MONGODB_CLOUD_LAST_ERROR="AWS_ACCESS_KEY_ID absent (.env.prod) et ~/.aws/credentials introuvable"
    return 3
  fi

  err_file="$(mktemp)"
  aws_cmd=(aws s3 cp "${archive}" "${uri}" --only-show-errors)
  [[ -n "${region}" ]] && aws_cmd+=(--region "${region}")

  if "${aws_cmd[@]}" 2>"${err_file}"; then
    rm -f "${err_file}"
    return 0
  fi
  rc=$?
  MONGODB_CLOUD_LAST_ERROR="$(tr '\n' ' ' < "${err_file}" | sed 's/  */ /g' | cut -c1-500)"
  rm -f "${err_file}"
  if [[ -z "${MONGODB_CLOUD_LAST_ERROR}" ]]; then
    MONGODB_CLOUD_LAST_ERROR="aws s3 cp exit ${rc} (vérifier clés IAM et s3:PutObject sur ${uri})"
  fi
  return 1
}

mongodb_cloud_backup_self_test() {
  local failures=0
  local day slot expected

  for day in 1 7 8 14 15 21 22 28 31; do
    slot="$(mongodb_cloud_backup_week_slot_for_day "${day}")"
    if (( day <= 7 )); then expected=1
    elif (( day <= 14 )); then expected=2
    elif (( day <= 21 )); then expected=3
    else expected=4
    fi
    if [[ "${slot}" != "${expected}" ]]; then
      echo "FAIL day=${day} slot=${slot} expected=${expected}" >&2
      failures=$((failures + 1))
    fi
  done

  if [[ "$(mongodb_cloud_backup_object_name 3)" != "Backup_DB_3.tar.gz" ]]; then
    echo "FAIL default object name" >&2
    failures=$((failures + 1))
  fi

  MONGO_CLOUD_BACKUP_PREFIX=Backup_DB_
  MONGO_CLOUD_BACKUP_ARCHIVE_EXT=.tar.gz
  if [[ "$(mongodb_cloud_backup_object_name 1)" != "Backup_DB_1.tar.gz" ]]; then
    echo "FAIL prefixed object name" >&2
    failures=$((failures + 1))
  fi
  unset MONGO_CLOUD_BACKUP_PREFIX MONGO_CLOUD_BACKUP_ARCHIVE_EXT

  if [[ "${failures}" -gt 0 ]]; then
    return 1
  fi
  echo "mongodb-cloud-backup self-test OK"
  return 0
}
