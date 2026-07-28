#!/usr/bin/env bash
# Harden an S3 bucket for production: Block Public Access, strip anonymous GetObject.
# Default: dry-run (inspect only). Set APPLY=1 to mutate.
#
# Usage:
#   ./scripts/harden-s3-bucket.sh                      # dry-run, bucket + keys from .env.prod
#   AWS_S3_BUCKET=wise-eat ./scripts/harden-s3-bucket.sh
#   APPLY=1 ./scripts/harden-s3-bucket.sh
#
# Credentials: exports AWS_* from /opt/wise-eat-api/.env.prod if not already set
# (same source as Mongo cloud backups). IAM needs:
#   s3:GetBucketPublicAccessBlock, s3:PutBucketPublicAccessBlock,
#   s3:GetBucketPolicy, s3:PutBucketPolicy / DeleteBucketPolicy
# Si la clé API n’a que Get/PutObject → utiliser la console AWS ou une clé admin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/api-env.sh
source "${SCRIPT_DIR}/lib/api-env.sh"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

APPLY="${APPLY:-0}"
REMOVE_PUBLIC_POLICY="${REMOVE_PUBLIC_POLICY:-1}"

# Charger bucket / région / clés depuis .env.prod si absents de l’environnement.
if [[ -z "${AWS_S3_BUCKET:-}" ]]; then
  AWS_S3_BUCKET="$(api_env_var AWS_S3_BUCKET 2>/dev/null || true)"
fi
if [[ -z "${AWS_REGION:-}" ]]; then
  AWS_REGION="$(api_env_var AWS_REGION 2>/dev/null || true)"
fi
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  AWS_ACCESS_KEY_ID="$(api_env_var AWS_ACCESS_KEY_ID 2>/dev/null || true)"
fi
if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  AWS_SECRET_ACCESS_KEY="$(api_env_var AWS_SECRET_ACCESS_KEY 2>/dev/null || true)"
fi
export AWS_S3_BUCKET AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

BUCKET="${AWS_S3_BUCKET:-}"
REGION="${AWS_REGION:-}"

[[ -n "${BUCKET}" ]] || die "Set AWS_S3_BUCKET or add it to ${API_ENV_FILE}"
BUCKET="${BUCKET#s3://}"
BUCKET="${BUCKET%%/*}"

command -v aws >/dev/null 2>&1 || die "aws CLI required"
command -v python3 >/dev/null 2>&1 || die "python3 required (policy rewrite)"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  if [[ ! -f "${HOME}/.aws/credentials" && -z "${AWS_PROFILE:-}" ]]; then
    die "AWS credentials missing. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or add them to ${API_ENV_FILE}"
  fi
else
  log "Using AWS_ACCESS_KEY_ID from env / ${API_ENV_FILE} (…${AWS_ACCESS_KEY_ID: -4})"
fi

AWS_ARGS=(--bucket "${BUCKET}")
[[ -n "${REGION}" ]] && AWS_ARGS+=(--region "${REGION}")

log "=== S3 harden: s3://${BUCKET} (APPLY=${APPLY} REGION=${REGION:-default}) ==="

# --- Inspect Block Public Access ---
bpa_json="$(aws s3api get-public-access-block "${AWS_ARGS[@]}" 2>/dev/null || echo '{}')"
log "PublicAccessBlock config:"
printf '%s\n' "${bpa_json}" | python3 -c '
import json,sys
try:
  d=json.load(sys.stdin).get("PublicAccessBlockConfiguration") or {}
except Exception:
  d={}
for k in ("BlockPublicAcls","IgnorePublicAcls","BlockPublicPolicy","RestrictPublicBuckets"):
  print(f"  {k}: {d.get(k, "missing")}")
' 2>/dev/null || log "  (unable to parse)"

all_blocked="$(printf '%s' "${bpa_json}" | python3 -c '
import json,sys
try:
  d=json.load(sys.stdin).get("PublicAccessBlockConfiguration") or {}
except Exception:
  d={}
keys=("BlockPublicAcls","IgnorePublicAcls","BlockPublicPolicy","RestrictPublicBuckets")
print("1" if all(d.get(k) is True for k in keys) else "0")
' 2>/dev/null || echo 0)"
log "All four Block Public Access flags ON: ${all_blocked}"

# --- Inspect bucket policy for anonymous principals ---
policy_raw="$(aws s3api get-bucket-policy "${AWS_ARGS[@]}" --output text 2>/dev/null || true)"
has_public_stmt=0
if [[ -n "${policy_raw}" ]]; then
  has_public_stmt="$(printf '%s' "${policy_raw}" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
  print(0); raise SystemExit
try:
  doc=json.loads(raw)
except Exception:
  print(0); raise SystemExit
stmts=doc.get("Statement") or []
if isinstance(stmts, dict):
  stmts=[stmts]

def principal_is_public(p):
  if p=="*": return True
  if isinstance(p, dict):
    aws=p.get("AWS")
    if aws=="*": return True
    if isinstance(aws, list) and "*" in aws: return True
  return False

n=0
for s in stmts:
  if str(s.get("Effect","")).lower()!="allow":
    continue
  if principal_is_public(s.get("Principal")):
    n+=1
print(1 if n else 0)
' 2>/dev/null || echo 0)"
  log "Bucket policy present: yes | anonymous Allow statements: ${has_public_stmt}"
else
  log "Bucket policy present: no"
fi

if [[ "${APPLY}" != "1" ]]; then
  log ""
  log "Dry-run only. Would apply:"
  [[ "${all_blocked}" != "1" ]] && log "  - put-public-access-block (all four flags true)"
  if [[ "${REMOVE_PUBLIC_POLICY}" == "1" && "${has_public_stmt}" == "1" ]]; then
    log "  - rewrite bucket policy: drop Principal \"*\" Allow statements"
  fi
  log ""
  log "Least privilege (manual — IAM user/role for API):"
  log "  - s3:GetObject, s3:PutObject, s3:DeleteObject on arn:aws:s3:::${BUCKET}/*"
  log "  - s3:ListBucket on arn:aws:s3:::${BUCKET}"
  log "  - Backups: same bucket prefix mongodb/* (authenticated)"
  log "Clients must use API proxy GET /medias/public/… (no CloudFront)."
  log "Docs: africa-meals-api/docs/S3_STORAGE.md"
  log "Re-run with APPLY=1 to mutate."
  exit 0
fi

# --- Apply Block Public Access ---
if [[ "${all_blocked}" != "1" ]]; then
  log "Enabling Block Public Access (all four flags)…"
  aws s3api put-public-access-block "${AWS_ARGS[@]}" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
else
  log "Block Public Access already fully enabled."
fi

# --- Strip anonymous Allow statements from bucket policy ---
if [[ "${REMOVE_PUBLIC_POLICY}" == "1" && -n "${policy_raw}" && "${has_public_stmt}" == "1" ]]; then
  log "Rewriting bucket policy (remove anonymous Allow)…"
  new_policy="$(printf '%s' "${policy_raw}" | python3 -c '
import json,sys
doc=json.loads(sys.stdin.read())
stmts=doc.get("Statement") or []
if isinstance(stmts, dict):
  stmts=[stmts]

def principal_is_public(p):
  if p=="*": return True
  if isinstance(p, dict):
    aws=p.get("AWS")
    if aws=="*": return True
    if isinstance(aws, list) and "*" in aws: return True
  return False

kept=[]
for s in stmts:
  if str(s.get("Effect","")).lower()=="allow" and principal_is_public(s.get("Principal")):
    continue
  kept.append(s)
doc["Statement"]=kept
print(json.dumps(doc))
')"
  stmt_count="$(printf '%s' "${new_policy}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("Statement") or []))')"
  if [[ "${stmt_count}" == "0" ]]; then
    log "No remaining statements — deleting bucket policy…"
    aws s3api delete-bucket-policy "${AWS_ARGS[@]}"
  else
    aws s3api put-bucket-policy "${AWS_ARGS[@]}" --policy "${new_policy}"
  fi
elif [[ "${REMOVE_PUBLIC_POLICY}" == "1" ]]; then
  log "No anonymous Allow statements to remove."
fi

log ""
log "Done. Verify media via API proxy /medias/public/ before relying on clients."
log "Docs: africa-meals-api/docs/S3_STORAGE.md"
log "Root: ${ROOT_DIR}"
