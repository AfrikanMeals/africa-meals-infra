#!/usr/bin/env bash
# Installe Prometheus + Grafana + redis_exporter sur le VPS Wise Eat.
# Usage : sudo bash install-monitoring.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_DIR="${MON_DIR:-/opt/wise-eat/monitoring}"
REDIS_ENV="${REDIS_ENV:-/opt/wise-eat/redis/.env.redis}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Exécuter en root : sudo bash $0" >&2
  exit 1
fi

mkdir -p "${MON_DIR}/scripts"
cp -r "${SCRIPT_DIR}/../prometheus" "${MON_DIR}/"
cp -r "${SCRIPT_DIR}/../grafana" "${MON_DIR}/"
cp "${SCRIPT_DIR}/../docker-compose.yml" "${MON_DIR}/"
cp "${SCRIPT_DIR}/../.env.example" "${MON_DIR}/.env.example"
cp "${SCRIPT_DIR}/fetch-grafana-dashboard.sh" "${MON_DIR}/scripts/"
chmod +x "${MON_DIR}/scripts/fetch-grafana-dashboard.sh"

if [[ ! -f "${MON_DIR}/.env.monitoring" ]]; then
  cp "${MON_DIR}/.env.example" "${MON_DIR}/.env.monitoring"
  chmod 600 "${MON_DIR}/.env.monitoring"
fi

if [[ -f "${REDIS_ENV}" ]]; then
  set -a && source "${REDIS_ENV}" && set +a
  if grep -q '^CACHE_REDIS_PASSWORD=$' "${MON_DIR}/.env.monitoring" 2>/dev/null || \
     ! grep -q '^CACHE_REDIS_PASSWORD=' "${MON_DIR}/.env.monitoring" 2>/dev/null; then
    sed -i "s|^CACHE_REDIS_PASSWORD=.*|CACHE_REDIS_PASSWORD=${CACHE_REDIS_PASSWORD}|" "${MON_DIR}/.env.monitoring" || true
  fi
  if grep -q '^BULL_REDIS_PASSWORD=$' "${MON_DIR}/.env.monitoring" 2>/dev/null || \
     ! grep -q '^BULL_REDIS_PASSWORD=' "${MON_DIR}/.env.monitoring" 2>/dev/null; then
    sed -i "s|^BULL_REDIS_PASSWORD=.*|BULL_REDIS_PASSWORD=${BULL_REDIS_PASSWORD}|" "${MON_DIR}/.env.monitoring" || true
  fi
fi

set -a && source "${MON_DIR}/.env.monitoring" && set +a

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}|" "${MON_DIR}/.env.monitoring"
  echo "Mot de passe Grafana admin généré (voir ${MON_DIR}/.env.monitoring)"
fi

bash "${MON_DIR}/scripts/fetch-grafana-dashboard.sh"

cd "${MON_DIR}"
docker compose --env-file .env.monitoring pull
docker compose --env-file .env.monitoring up -d

sleep 5
echo ""
echo "=== Statut ==="
docker compose --env-file .env.monitoring ps
echo ""
echo "Vérifier métriques cache : curl -s http://127.0.0.1:9121/metrics | grep redis_up"
echo "Vérifier métriques bull  : curl -s http://127.0.0.1:9122/metrics | grep redis_up"
echo ""
echo "Grafana (SSH tunnel) : ssh -L 3000:127.0.0.1:3000 root@wise-eat.cloud"
echo "  → http://127.0.0.1:3000  user=${GRAFANA_ADMIN_USER:-admin}"
echo "Prometheus           : ssh -L 9090:127.0.0.1:9090 root@wise-eat.cloud → http://127.0.0.1:9090"
