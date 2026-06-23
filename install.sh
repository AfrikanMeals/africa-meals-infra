#!/usr/bin/env bash
# Wise Eat — installation infra VPS par composant.
#
# Usage:
#   sudo ./install.sh redis
#   sudo GCP_EGRESS_IP=x.x.x.x ./install.sh stunnel
#   sudo ./install.sh monitoring
#   sudo ./install.sh permissions
#   sudo ./install.sh all
#   ./install.sh --help
#
# Variables:
#   WISE_EAT_ROOT   Racine déploiement (défaut : répertoire de ce dépôt)
#   GCP_EGRESS_IP   Requis pour stunnel (IP egress Cloud Functions)
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${INFRA_ROOT}/scripts"

usage() {
  cat <<EOF
Wise Eat — installateur infra VPS

Usage:
  sudo $0 <composant> [composant...]
  sudo $0 all

Composants:
  redis         Redis Docker (cache :6379 + BullMQ :6380), secrets + ACL
  stunnel       Stunnel TLS Mode A (:6381 / :6382) — requiert GCP_EGRESS_IP
  monitoring    Prometheus + Grafana + redis_exporter
  permissions   Corrige ACL/data (UID 999) sans regénérer les secrets
  all           redis + permissions + monitoring (pas stunnel)

Exemples:
  sudo $0 redis
  sudo GCP_EGRESS_IP=203.0.113.50 $0 stunnel
  sudo $0 redis monitoring
  sudo $0 all

Env:
  WISE_EAT_ROOT=${WISE_EAT_ROOT:-$INFRA_ROOT}
  GCP_EGRESS_IP=<ip>   (stunnel)

Docs: README.md · docs/REDIS_VPS_PRODUCTION.md (monorepo AfrikaMeals)
EOF
}

run_component() {
  local name="$1"
  case "${name}" in
    redis)
      bash "${SCRIPTS}/install-redis.sh"
      ;;
    stunnel)
      bash "${SCRIPTS}/install-stunnel.sh"
      ;;
    monitoring)
      bash "${SCRIPTS}/install-monitoring.sh"
      ;;
    permissions)
      bash "${SCRIPTS}/fix-redis-permissions.sh"
      ;;
    all)
      bash "${SCRIPTS}/install-redis.sh"
      bash "${SCRIPTS}/fix-redis-permissions.sh"
      bash "${SCRIPTS}/install-monitoring.sh"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "Composant inconnu : ${name}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

for arg in "$@"; do
  run_component "${arg}"
done
