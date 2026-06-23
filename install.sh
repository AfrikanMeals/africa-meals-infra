#!/usr/bin/env bash
# Wise Eat — installation infra VPS par composant.
#
# Usage:
#   sudo ./install.sh redis
#   sudo ./install.sh stunnel              # Mode A-lite (défaut prod)
#   sudo GCP_EGRESS_IP=x.x.x.x ./install.sh stunnel   # A-strict (Cloud NAT)
#   sudo ./install.sh monitoring
#   sudo ./install.sh permissions
#   sudo ./install.sh all
#   ./install.sh --help
#
# Variables:
#   WISE_EAT_ROOT   Racine déploiement (défaut : répertoire de ce dépôt)
#   GCP_EGRESS_IP         Optionnel — A-strict (Cloud NAT + IP statique)
#   STUNNEL_AUTH_ONLY=1   A-lite explicite (défaut si GCP_EGRESS_IP absent)
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
  stunnel       Stunnel TLS Mode A-lite (:6381 / :6382) — défaut prod, sans Cloud NAT
  monitoring    Prometheus + Grafana + redis_exporter
  permissions   Corrige ACL/data (UID 999) sans regénérer les secrets
  all           redis + permissions + monitoring (pas stunnel)

Stunnel :
  sudo $0 stunnel                           # A-lite (prod, ~0 €)
  sudo GCP_EGRESS_IP=x.x.x.x $0 stunnel     # A-strict (Cloud NAT, optionnel)

Exemples:
  sudo $0 redis
  sudo $0 stunnel
  sudo GCP_EGRESS_IP=203.0.113.50 $0 stunnel
  sudo $0 redis monitoring
  sudo $0 all

Env:
  WISE_EAT_ROOT=${WISE_EAT_ROOT:-$INFRA_ROOT}
  GCP_EGRESS_IP=<ip>   A-strict optionnel (Cloud NAT)

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
