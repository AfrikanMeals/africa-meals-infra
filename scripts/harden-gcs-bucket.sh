#!/usr/bin/env bash
# Harden a GCS bucket for production: PAP, no allUsers, optional versioning.
# Default: dry-run (inspect only). Set APPLY=1 to mutate.
#
# Usage:
#   ./scripts/harden-gcs-bucket.sh                 # dry-run, bucket from GCS_BUCKET
#   GCS_BUCKET=wise-eat-store ./scripts/harden-gcs-bucket.sh
#   APPLY=1 ENABLE_VERSIONING=1 ./scripts/harden-gcs-bucket.sh
#
# Requires: gcloud auth with storage.admin (or equivalent) on the project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

BUCKET="${GCS_BUCKET:-${GOOGLE_CLOUD_STORAGE_BUCKET:-}}"
APPLY="${APPLY:-0}"
ENABLE_VERSIONING="${ENABLE_VERSIONING:-1}"
REMOVE_PUBLIC="${REMOVE_PUBLIC:-1}"

if [[ -z "${BUCKET}" ]]; then
  # Try API env on VPS layout
  API_ENV="${MONGO_CLOUD_API_ENV:-/opt/wise-eat-api/.env.prod}"
  if [[ -f "${API_ENV}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1091
    source <(grep -E '^(GCS_BUCKET|GOOGLE_CLOUD_STORAGE_BUCKET)=' "${API_ENV}" | sed 's/\r$//' || true)
    set +a
    BUCKET="${GCS_BUCKET:-${GOOGLE_CLOUD_STORAGE_BUCKET:-}}"
  fi
fi

[[ -n "${BUCKET}" ]] || die "Set GCS_BUCKET (e.g. wise-eat-store)"
BUCKET="${BUCKET#gs://}"
BUCKET="${BUCKET%%/*}"
GS="gs://${BUCKET}"

command -v gcloud >/dev/null 2>&1 || die "gcloud CLI required"

log "=== GCS harden: ${GS} (APPLY=${APPLY} VERSIONING=${ENABLE_VERSIONING}) ==="

# --- Inspect PAP ---
pap_raw="$(gcloud storage buckets describe "${GS}" --format='value(public_access_prevention)' 2>/dev/null || true)"
pap="$(echo "${pap_raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
log "PAP current: ${pap:-unknown}"

# --- Inspect IAM public principals ---
iam_json="$(gcloud storage buckets get-iam-policy "${GS}" --format=json 2>/dev/null || echo '{}')"
has_all_users=0
has_all_auth=0
if echo "${iam_json}" | grep -q 'allUsers'; then has_all_users=1; fi
if echo "${iam_json}" | grep -q 'allAuthenticatedUsers'; then has_all_auth=1; fi
log "IAM allUsers: ${has_all_users} | allAuthenticatedUsers: ${has_all_auth}"

# --- Inspect versioning ---
ver_raw="$(gcloud storage buckets describe "${GS}" --format='value(versioning_enabled)' 2>/dev/null || true)"
log "Versioning enabled: ${ver_raw:-unknown}"

if [[ "${APPLY}" != "1" ]]; then
  log ""
  log "Dry-run only. Would apply:"
  [[ "${pap}" != "enforced" ]] && log "  - gcloud storage buckets update ${GS} --public-access-prevention"
  if [[ "${REMOVE_PUBLIC}" == "1" ]]; then
    [[ "${has_all_users}" == "1" ]] && log "  - remove allUsers from bucket IAM"
    [[ "${has_all_auth}" == "1" ]] && log "  - remove allAuthenticatedUsers from bucket IAM"
  fi
  if [[ "${ENABLE_VERSIONING}" == "1" && "${ver_raw}" != "True" && "${ver_raw}" != "true" ]]; then
    log "  - gcloud storage buckets update ${GS} --versioning"
  fi
  log ""
  log "Least privilege (manual — grant on bucket only, not project Editor):"
  log "  - API SA: roles/storage.objectAdmin on ${GS}"
  log "  - Backup SA: roles/storage.objectAdmin (or objectCreator+Viewer) on ${GS}/mongodb/"
  log "Re-run with APPLY=1 to mutate."
  exit 0
fi

# --- Apply PAP ---
if [[ "${pap}" != "enforced" ]]; then
  log "Enforcing public access prevention…"
  gcloud storage buckets update "${GS}" --public-access-prevention
else
  log "PAP already enforced."
fi

# --- Remove public IAM ---
if [[ "${REMOVE_PUBLIC}" == "1" ]]; then
  if [[ "${has_all_users}" == "1" ]]; then
    log "Removing allUsers bindings…"
    # Binding roles vary (objectViewer / legacyBucketReader) — remove common ones.
    for role in roles/storage.objectViewer roles/storage.legacyObjectReader roles/storage.legacyBucketReader; do
      gcloud storage buckets remove-iam-policy-binding "${GS}" \
        --member=allUsers --role="${role}" >/dev/null 2>&1 || true
    done
  fi
  if [[ "${has_all_auth}" == "1" ]]; then
    log "Removing allAuthenticatedUsers bindings…"
    for role in roles/storage.objectViewer roles/storage.legacyObjectReader roles/storage.legacyBucketReader; do
      gcloud storage buckets remove-iam-policy-binding "${GS}" \
        --member=allAuthenticatedUsers --role="${role}" >/dev/null 2>&1 || true
    done
  fi
fi

# --- Versioning ---
if [[ "${ENABLE_VERSIONING}" == "1" ]]; then
  if [[ "${ver_raw}" == "True" || "${ver_raw}" == "true" ]]; then
    log "Versioning already on."
  else
    log "Enabling object versioning…"
    gcloud storage buckets update "${GS}" --versioning
  fi
fi

log ""
log "Done. Verify media via API proxy /medias/public/ before relying on clients."
log "Docs: africa-meals-api/docs/FIREBASE_STORAGE.md (Production private bucket)"
log "Root: ${ROOT_DIR}"
