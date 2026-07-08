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

mongodb_cloud_backup_resolve_google_creds() {
  local explicit="$1"
  local recaptcha_path wise_eat_com_sa default_sa

  if [[ -n "${explicit}" ]]; then
    explicit="$(api_env_resolve_path "${explicit}")"
    if [[ -f "${explicit}" ]]; then
      echo "${explicit}"
      return 0
    fi
  fi

  recaptcha_path="$(api_env_var RECAPTCHA_ENTERPRISE_SERVICE_ACCOUNT_PATH 2>/dev/null || true)"
  if [[ -n "${recaptcha_path}" ]]; then
    wise_eat_com_sa="$(api_env_resolve_path "${recaptcha_path}")"
    [[ -f "${wise_eat_com_sa}" ]] && echo "${wise_eat_com_sa}" && return 0
  fi
  if [[ -f "${API_ENV_DIR}/recaptcha-accounts.json" ]]; then
    echo "${API_ENV_DIR}/recaptcha-accounts.json"
    return 0
  fi

  default_sa="$(api_env_first_set GOOGLE_APPLICATION_CREDENTIALS AM_FIREBASE_SERVICE_ACCOUNT_PATH 2>/dev/null || true)"
  if [[ -n "${default_sa}" ]]; then
    default_sa="$(api_env_resolve_path "${default_sa}")"
    [[ -f "${default_sa}" ]] && echo "${default_sa}" && return 0
  fi
  if [[ -f "${API_ENV_DIR}/accounts.json" ]]; then
    echo "${API_ENV_DIR}/accounts.json"
    return 0
  fi
  return 1
}

mongodb_cloud_backup_resolve_firebase_creds() {
  local firebase_bucket="${1:-}"
  local recaptcha_path wise_eat_com_sa default_sa

  if [[ -n "${MONGO_CLOUD_FIREBASE_CREDENTIALS:-}" ]]; then
    MONGO_CLOUD_FIREBASE_CREDENTIALS="$(api_env_resolve_path "${MONGO_CLOUD_FIREBASE_CREDENTIALS}")"
    [[ -f "${MONGO_CLOUD_FIREBASE_CREDENTIALS}" ]] && echo "${MONGO_CLOUD_FIREBASE_CREDENTIALS}" && return 0
  fi

  # Bucket Firebase wise-eat-com → SA wise-eat-com (recaptcha-accounts.json)
  if [[ "${firebase_bucket}" == *wise-eat-com* ]]; then
    recaptcha_path="$(api_env_var RECAPTCHA_ENTERPRISE_SERVICE_ACCOUNT_PATH 2>/dev/null || true)"
    if [[ -n "${recaptcha_path}" ]]; then
      wise_eat_com_sa="$(api_env_resolve_path "${recaptcha_path}")"
      [[ -f "${wise_eat_com_sa}" ]] && echo "${wise_eat_com_sa}" && return 0
    fi
    if [[ -f "${API_ENV_DIR}/recaptcha-accounts.json" ]]; then
      echo "${API_ENV_DIR}/recaptcha-accounts.json"
      return 0
    fi
  fi

  mongodb_cloud_backup_resolve_google_creds "" || return 1
}

mongodb_cloud_backup_apply_api_env() {
  local api_env="${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}"
  local prefix gcs_bucket firebase_bucket aws_bucket aws_region google_creds firebase_creds

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

  if [[ -z "${MONGO_CLOUD_GCS_CREDENTIALS:-}" ]]; then
    google_creds="$(mongodb_cloud_backup_resolve_google_creds "" 2>/dev/null || true)"
    [[ -n "${google_creds}" ]] && MONGO_CLOUD_GCS_CREDENTIALS="${google_creds}"
  else
    MONGO_CLOUD_GCS_CREDENTIALS="$(api_env_resolve_path "${MONGO_CLOUD_GCS_CREDENTIALS}")"
  fi

  firebase_creds="$(mongodb_cloud_backup_resolve_firebase_creds "${firebase_bucket}" 2>/dev/null || true)"
  [[ -n "${firebase_creds}" ]] && MONGO_CLOUD_FIREBASE_CREDENTIALS="${firebase_creds}"

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
  local slot aws_key_mask
  slot="$(mongodb_cloud_backup_week_slot 2>/dev/null || echo "?")"
  echo "API env     : ${API_ENV_FILE:-${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}}"
  echo "Slot actuel : Backup_DB_${slot} (semaine du mois)"
  echo "GCS         : enabled=${MONGO_CLOUD_GCS_ENABLED:-0} uri=${MONGO_CLOUD_GCS_URI:-—}"
  echo "  creds     : ${MONGO_CLOUD_GCS_CREDENTIALS:-—}"
  echo "Firebase    : enabled=${MONGO_CLOUD_FIREBASE_ENABLED:-0} uri=${MONGO_CLOUD_FIREBASE_URI:-—}"
  echo "  creds     : ${MONGO_CLOUD_FIREBASE_CREDENTIALS:-—}"
  echo "AWS S3      : enabled=${MONGO_CLOUD_AWS_ENABLED:-0} uri=${MONGO_CLOUD_AWS_URI:-—} region=${MONGO_CLOUD_AWS_REGION:-—}"
  if [[ -n "${MONGO_CLOUD_AWS_ACCESS_KEY_ID:-}" ]]; then
    aws_key_mask="${MONGO_CLOUD_AWS_ACCESS_KEY_ID:0:4}…${MONGO_CLOUD_AWS_ACCESS_KEY_ID: -4}"
    echo "  AWS key   : ${aws_key_mask} (depuis .env.prod)"
  else
    echo "  AWS key   : — (AWS_ACCESS_KEY_ID absent)"
  fi
}

mongodb_cloud_backup_preflight() {
  local issues=0

  echo "=== Outils CLI ==="
  if mongodb_cloud_backup_has_gs_cli; then
    if command -v gcloud >/dev/null 2>&1; then
      echo "OK  gcloud $(gcloud version 2>/dev/null | head -1 || echo present)"
    else
      echo "OK  gsutil $(gsutil version 2>/dev/null | head -1 || echo present)"
    fi
  else
    echo "FAIL gcloud/gsutil absent — sudo ./install.sh mongodb-cloud-tools"
    issues=$((issues + 1))
  fi
  if command -v aws >/dev/null 2>&1; then
    echo "OK  aws $(aws --version 2>&1 | head -1)"
  else
    echo "FAIL aws CLI absent — sudo ./install.sh mongodb-cloud-tools"
    issues=$((issues + 1))
  fi

  echo ""
  echo "=== Credentials ==="
  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_GCS_ENABLED:-0}"; then
    if [[ -f "${MONGO_CLOUD_GCS_CREDENTIALS:-}" ]]; then
      echo "OK  GCS SA : ${MONGO_CLOUD_GCS_CREDENTIALS}"
    else
      echo "FAIL GCS SA absent (accounts.json ou GOOGLE_APPLICATION_CREDENTIALS)"
      issues=$((issues + 1))
    fi
  fi
  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_FIREBASE_ENABLED:-0}"; then
    if [[ -f "${MONGO_CLOUD_FIREBASE_CREDENTIALS:-}" ]]; then
      echo "OK  Firebase SA : ${MONGO_CLOUD_FIREBASE_CREDENTIALS}"
    else
      echo "FAIL Firebase SA absent (recaptcha-accounts.json pour wise-eat-com)"
      issues=$((issues + 1))
    fi
  fi
  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_AWS_ENABLED:-0}"; then
    if [[ -n "${MONGO_CLOUD_AWS_ACCESS_KEY_ID:-}" ]] && [[ -n "${MONGO_CLOUD_AWS_SECRET_ACCESS_KEY:-}" ]]; then
      echo "OK  AWS keys présentes (.env.prod)"
    else
      echo "FAIL AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY absents"
      issues=$((issues + 1))
    fi
  fi

  echo ""
  echo "=== Test écriture (fichier 1 octet) ==="
  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_GCS_ENABLED:-0}" && [[ -n "${MONGO_CLOUD_GCS_URI:-}" ]]; then
    local probe="${MONGO_CLOUD_GCS_URI}/.wise-eat-backup-probe"
    local tmp
    tmp="$(mktemp)"
    echo ok > "${tmp}"
    if mongodb_cloud_backup_run_gs_upload "${probe}" "${tmp}" "${MONGO_CLOUD_GCS_CREDENTIALS:-}"; then
      echo "OK  GCS write probe"
    else
      echo "FAIL GCS : ${MONGODB_CLOUD_LAST_ERROR}"
      issues=$((issues + 1))
    fi
    rm -f "${tmp}"
  fi

  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_FIREBASE_ENABLED:-0}" && [[ -n "${MONGO_CLOUD_FIREBASE_URI:-}" ]]; then
    local probe="${MONGO_CLOUD_FIREBASE_URI}/.wise-eat-backup-probe"
    local tmp
    tmp="$(mktemp)"
    echo ok > "${tmp}"
    if mongodb_cloud_backup_run_gs_upload "${probe}" "${tmp}" "${MONGO_CLOUD_FIREBASE_CREDENTIALS:-}"; then
      echo "OK  Firebase write probe"
    else
      echo "FAIL Firebase : ${MONGODB_CLOUD_LAST_ERROR}"
      issues=$((issues + 1))
    fi
    rm -f "${tmp}"
  fi

  if mongodb_cloud_backup_env_truthy "${MONGO_CLOUD_AWS_ENABLED:-0}" && [[ -n "${MONGO_CLOUD_AWS_URI:-}" ]]; then
    local probe="${MONGO_CLOUD_AWS_URI}/.wise-eat-backup-probe"
    local tmp
    tmp="$(mktemp)"
    echo ok > "${tmp}"
    export AWS_ACCESS_KEY_ID="${MONGO_CLOUD_AWS_ACCESS_KEY_ID:-}"
    export AWS_SECRET_ACCESS_KEY="${MONGO_CLOUD_AWS_SECRET_ACCESS_KEY:-}"
    if mongodb_cloud_backup_run_aws_upload "${probe}" "${tmp}" "${MONGO_CLOUD_AWS_REGION:-}"; then
      echo "OK  AWS S3 write probe"
    else
      echo "FAIL AWS : ${MONGODB_CLOUD_LAST_ERROR}"
      issues=$((issues + 1))
    fi
    rm -f "${tmp}"
  fi

  echo ""
  if [[ "${issues}" -gt 0 ]]; then
    echo "Preflight : ${issues} problème(s) — corriger avant upload cloud"
    return 1
  fi
  echo "Preflight OK — prêt pour upload cloud"
  return 0
}
