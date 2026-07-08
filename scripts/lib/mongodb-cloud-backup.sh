#!/usr/bin/env bash
# Helpers — sauvegarde MongoDB off-site (GCS, Firebase Storage, AWS S3).
# Rotation mensuelle : Backup_DB_1 … Backup_DB_4 (écrasement du même slot chaque mois).
set -euo pipefail

# Semaine du mois (1–4) à partir du jour calendaire :
#   jours 1–7   → 1   jours 8–14  → 2   jours 15–21 → 3   jours 22+ → 4
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

mongodb_cloud_backup_run_gs_upload() {
  local uri="$1"
  local archive="$2"
  local credentials="${3:-}"

  if [[ -n "${credentials}" ]]; then
    [[ -f "${credentials}" ]] || return 1
    export GOOGLE_APPLICATION_CREDENTIALS="${credentials}"
  fi

  if command -v gcloud >/dev/null 2>&1; then
    gcloud storage cp --quiet "${archive}" "${uri}"
    return 0
  fi
  if command -v gsutil >/dev/null 2>&1; then
    gsutil -q cp "${archive}" "${uri}"
    return 0
  fi
  return 1
}

mongodb_cloud_backup_run_aws_upload() {
  local uri="$1"
  local archive="$2"
  local region="${3:-}"

  command -v aws >/dev/null 2>&1 || return 1
  if [[ -n "${region}" ]]; then
    aws s3 cp "${archive}" "${uri}" --region "${region}" --only-show-errors
  else
    aws s3 cp "${archive}" "${uri}" --only-show-errors
  fi
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
