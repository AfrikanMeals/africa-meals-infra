#!/usr/bin/env bash
# Vérifie AWS S3 depuis /opt/wise-eat-api/.env.prod (diagnostic signature / région / horloge).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/api-env.sh
source "${SCRIPT_DIR}/lib/api-env.sh"

API_ENV_FILE="${1:-/opt/wise-eat-api/.env.prod}"
export API_ENV_FILE

[[ -f "${API_ENV_FILE}" ]] || die "Absent : ${API_ENV_FILE}"

BUCKET="$(api_env_var AWS_S3_BUCKET 2>/dev/null || true)"
REGION="$(api_env_first_set AWS_REGION AWS_DEFAULT_REGION 2>/dev/null || true)"
KEY_ID="$(api_env_var AWS_ACCESS_KEY_ID 2>/dev/null || true)"
SECRET="$(api_env_var AWS_SECRET_ACCESS_KEY 2>/dev/null || true)"
RAW_LINE="$(grep -E '^AWS_SECRET_ACCESS_KEY=' "${API_ENV_FILE}" 2>/dev/null | tail -n 1 || true)"

echo "=== AWS S3 diagnostic ==="
echo "Fichier      : ${API_ENV_FILE}"
echo "Bucket       : ${BUCKET:-—}"
echo "Region       : ${REGION:-us-east-1}"
echo "Access key   : ${KEY_ID:0:4}…${KEY_ID: -4}"
echo "Secret len   : ${#SECRET} caractères (après normalisation guillemets)"
if [[ "${RAW_LINE}" == *'="'* ]] || [[ "${RAW_LINE}" == *'"'* ]]; then
  echo "ATTENTION    : guillemets détectés dans .env — kubectl les incluait avant correctif create-api-secret.sh"
fi

echo ""
echo "=== Horloge VPS (signature AWS sensible au décalage > 5 min) ==="
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl status | grep -E 'Local time|System clock synchronized|NTP service' || timedatectl
else
  date -u && date
fi

[[ -n "${BUCKET}" && -n "${KEY_ID}" && -n "${SECRET}" ]] || die "AWS_S3_BUCKET / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY incomplets"

command -v aws >/dev/null 2>&1 || die "aws CLI absent — sudo ./install.sh mongodb-cloud-tools"

export AWS_ACCESS_KEY_ID="${KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${SECRET}"
REGION="${REGION:-us-east-1}"

echo ""
echo "=== Test aws s3 ls ==="
if aws s3 ls "s3://${BUCKET}/" --region "${REGION}" 2>&1; then
  echo "OK  ListBucket"
else
  echo "FAIL ListBucket — si « signature does not match » : retirer les guillemets de AWS_SECRET_ACCESS_KEY dans .env.prod puis :"
  echo "  sudo k8s/scripts/create-api-secret.sh ${API_ENV_FILE}"
  echo "  sudo kubectl rollout restart deployment -n wise-eat -l app=africa-meals-api"
  exit 1
fi

PROBE="mongodb/.wise-eat-aws-probe-$$"
TMP="$(mktemp)"
echo ok > "${TMP}"
echo ""
echo "=== Test aws s3 cp (upload) ==="
if aws s3 cp "${TMP}" "s3://${BUCKET}/${PROBE}" --region "${REGION}" 2>&1; then
  echo "OK  PutObject"
  aws s3 rm "s3://${BUCKET}/${PROBE}" --region "${REGION}" 2>/dev/null || true
else
  rm -f "${TMP}"
  exit 1
fi
rm -f "${TMP}"
echo ""
echo "AWS S3 OK depuis ${API_ENV_FILE}"
