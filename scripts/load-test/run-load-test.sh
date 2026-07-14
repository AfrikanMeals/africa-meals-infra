#!/usr/bin/env bash
# Lance le test de charge k6 contre api.wise-eat.com + ws.wise-eat.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${LOAD_TEST_ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Fichier ${ENV_FILE} introuvable." >&2
  echo "  cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}" >&2
  echo "  chmod 600 ${ENV_FILE}" >&2
  echo "  # renseigner LOAD_TEST_EMAIL et LOAD_TEST_PASSWORD" >&2
  exit 1
fi

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 n'est pas installé." >&2
  echo "  macOS : brew install k6" >&2
  echo "  Linux : https://grafana.com/docs/k6/latest/set-up/install-k6/" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "${ENV_FILE}" && set +a

if [[ -z "${LOAD_TEST_AUTH_TOKEN:-}" ]]; then
  : "${LOAD_TEST_EMAIL:?LOAD_TEST_EMAIL requis dans ${ENV_FILE}}"
  : "${LOAD_TEST_PASSWORD:?LOAD_TEST_PASSWORD requis dans ${ENV_FILE}}"
fi

VUS="${LOAD_TEST_VUS:-10}"
TARGET="${LOAD_TEST_TARGET:-both}"

echo "=== Wise Eat load test ==="
echo "API  : ${LOAD_TEST_API_BASE:-https://api.wise-eat.com/api}"
echo "WS   : ${LOAD_TEST_WS_BASE:-https://ws.wise-eat.com}"
ITERS="${LOAD_TEST_ITERATIONS:-0}"
if [[ "${ITERS}" -gt 0 ]]; then
  echo "VUs  : ${VUS} | cible : ${TARGET} | itérations : ${ITERS}"
else
  echo "VUs  : ${VUS} | cible : ${TARGET} | durée : ${LOAD_TEST_DURATION:-1m}"
fi
echo ""
echo "Attention : test sur PRODUCTION — rate-limit login (15 / 15 min / IP)."
echo "Le script ne login qu'une fois (setup k6) ; augmenter VUs pour simuler la charge."
if [[ "${ITERS}" -gt 0 ]]; then
  echo "Mode itérations : 1 itération ≈ 1 tour d’endpoints (plusieurs HTTP req par tour)."
fi
if [[ "${VUS}" -gt 500 ]]; then
  echo ""
  echo "AVERTISSEMENT : ${VUS} VUs — charge extrême depuis une seule IP (rate-limit, timeouts)."
  echo "  Recommandé : LOAD_TEST_VUS<=100 pour un test représentatif."
fi
echo ""

# Variables déjà exportées via `source .env` — k6 les lit via __ENV.* (pas de --env-file, absent sur certaines versions).
exec k6 run "${SCRIPT_DIR}/load-test.k6.js" "$@"
