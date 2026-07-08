#!/usr/bin/env bash
# Résout URIs et credentials cloud depuis /opt/wise-eat-api/.env.prod (+ overrides .env.mongodb).
set -euo pipefail

# shellcheck source=api-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/api-env.sh"

mongodb_cloud_backup_env_truthy() {
  local raw="${1:-}"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]')"
  [[ "${raw}" == "1" || "${raw}" == "true" || "${raw}" == "yes" || "${raw}" == "on" ]]
}

mongodb_cloud_backup_apply_api_env() {
  local api_env="${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}"
  local prefix gcs_bucket firebase_bucket aws_bucket aws_region google_creds resolved

  API_ENV_FILE="${api_env}"
  API_ENV_DIR="$(dirname "${api_env}")"

  [[ -f "${API_ENV_FILE}" ]] || die "Credentials API absents : ${API_ENV_FILE} (copier africa-meals-api/.env.prod sur le VPS)"

  prefix="${MONGO_CLOUD_OBJECT_PREFIX:-mongodb}"

  gcs_bucket="$(api_env_first_set GCS_BUCKET GOOGLE_CLOUD_STORAGE_BUCKET 2>/dev/null || true)"
  if [[ -z "${MONGO_CLOUD_GCS_URI:-}" ]] && [[ -n "${gcs_bucket}" ]]; then
    gcs_bucket="${gcs_bucket#gs://}"
    MONGO_CLOUD_GCS_URI="gs://${gcs_bucket}/${prefix}"
  fi

  firebase_bucket="$(api_env_var AM_FIREBASE_STORAGE_BUCKET 2>/dev/null || true)"
  if [[ -z "${MONGO_CLOUD_FIREBASE_URI:-}" ]] && [[ -n "${firebase_bucket}" ]]; then
    firebase_bucket="${firebase_bucket#gs://}"
    MONGO_CLOUD_FIREBASE_URI="gs://${firebase_bucket}/${prefix}"
  fi

  aws_bucket="$(api_env_var AWS_S3_BUCKET 2>/dev/null || true)"
  aws_region="$(api_env_first_set AWS_REGION AWS_DEFAULT_REGION 2>/dev/null || true)"
  if [[ -z "${MONGO_CLOUD_AWS_URI:-}" ]] && [[ -n "${aws_bucket}" ]]; then
    aws_bucket="${aws_bucket#s3://}"
    MONGO_CLOUD_AWS_URI="s3://${aws_bucket}/${prefix}"
  fi
  if [[ -z "${MONGO_CLOUD_AWS_REGION:-}" ]] && [[ -n "${aws_region}" ]]; then
    MONGO_CLOUD_AWS_REGION="${aws_region}"
  fi
  if [[ -z "${MONGO_CLOUD_AWS_ACCESS_KEY_ID:-}" ]]; then
    MONGO_CLOUD_AWS_ACCESS_KEY_ID="$(api_env_var AWS_ACCESS_KEY_ID 2>/dev/null || true)"
  fi
  if [[ -z "${MONGO_CLOUD_AWS_SECRET_ACCESS_KEY:-}" ]]; then
    MONGO_CLOUD_AWS_SECRET_ACCESS_KEY="$(api_env_var AWS_SECRET_ACCESS_KEY 2>/dev/null || true)"
  fi

  google_creds="$(api_env_first_set GOOGLE_APPLICATION_CREDENTIALS AM_FIREBASE_SERVICE_ACCOUNT_PATH 2>/dev/null || true)"
  if [[ -n "${google_creds}" ]]; then
    google_creds="$(api_env_resolve_path "${google_creds}")"
  fi
  if [[ -z "${google_creds}" || ! -f "${google_creds}" ]]; then
    if [[ -f "${API_ENV_DIR}/accounts.json" ]]; then
      google_creds="${API_ENV_DIR}/accounts.json"
    fi
  fi

  if [[ -z "${MONGO_CLOUD_GCS_CREDENTIALS:-}" ]] && [[ -n "${google_creds}" ]] && [[ -f "${google_creds}" ]]; then
    MONGO_CLOUD_GCS_CREDENTIALS="${google_creds}"
  fi
  if [[ -z "${MONGO_CLOUD_FIREBASE_CREDENTIALS:-}" ]] && [[ -n "${google_creds}" ]] && [[ -f "${google_creds}" ]]; then
    MONGO_CLOUD_FIREBASE_CREDENTIALS="${google_creds}"
  fi

  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_AUTO_ENABLE_DESTINATIONS:-1}"; then
    if [[ -n "${MONGO_CLOUD_GCS_URI:-}" ]] && ! mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_GCS_ENABLED:-0}"; then
      if [[ -n "${gcs_bucket}" ]]; then
        MONGO_CLOUD_GCS_ENABLED=1
      fi
    fi
    if [[ -n "${MONGO_CLOUD_FIREBASE_URI:-}" ]] && ! mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_FIREBASE_ENABLED:-0}"; then
      if [[ -n "${firebase_bucket}" ]]; then
        MONGO_CLOUD_FIREBASE_ENABLED=1
      fi
    fi
    if [[ -n "${MONGO_CLOUD_AWS_URI:-}" ]] && ! mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_AWS_ENABLED:-0}"; then
      if [[ -n "${aws_bucket}" ]] && [[ -n "${MONGO_CLOUD_AWS_ACCESS_KEY_ID:-}" ]]; then
        MONGO_CLOUD_AWS_ENABLED=1
      fi
    fi
  fi

  export MONGO_CLOUD_GCS_URI MONGO_CLOUD_FIREBASE_URI MONGO_CLOUD_AWS_URI MONGO_CLOUD_AWS_REGION
  export MONGO_CLOUD_AWS_ACCESS_KEY_ID MONGO_CLOUD_AWS_SECRET_ACCESS_KEY
  export MONGO_CLOUD_GCS_CREDENTIALS MONGO_CLOUD_FIREBASE_CREDENTIALS
  export MONGO_CLOUD_GCS_ENABLED MONGO_CLOUD_FIREBASE_ENABLED MONGO_CLOUD_AWS_ENABLED
}

mongodb_cloud_backup_print_env_summary() {
  local slot
  slot="$(mongodb_cloud_backup_week_slot 2>/dev/null || echo "?")"
  echo "API env     : ${API_ENV_FILE:-${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}}"
  echo "Slot actuel : Backup_DB_${slot} (semaine du mois)"
  echo "GCS         : enabled=${MONGO_CLOUD_GCS_ENABLED:-0} uri=${MONGO_CLOUD_GCS_URI:-—}"
  echo "Firebase    : enabled=${MONGO_CLOUD_FIREBASE_ENABLED:-0} uri=${MONGO_CLOUD_FIREBASE_URI:-—}"
  echo "AWS S3      : enabled=${MONGO_CLOUD_AWS_ENABLED:-0} uri=${MONGO_CLOUD_AWS_URI:-—} region=${MONGO_CLOUD_AWS_REGION:-—}"
  if [[ -n "${MONGO_CLOUD_GCS_CREDENTIALS:-}" ]]; then
    echo "Google SA   : ${MONGO_CLOUD_GCS_CREDENTIALS}"
  else
    echo "Google SA   : — (GOOGLE_APPLICATION_CREDENTIALS ou accounts.json)"
  fi
}
