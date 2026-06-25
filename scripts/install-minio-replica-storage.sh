#!/usr/bin/env bash
# nginx + TLS Let's Encrypt pour MinIO réplicas DR (dr1-storage, dr2-storage).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/certbot.sh
source "${SCRIPT_DIR}/lib/certbot.sh"

require_root

if [[ -f "${MINIO_ENV}" ]]; then
  set -a && source "${MINIO_ENV}" && set +a
fi

MINIO_REPLICA_1_STORAGE_DOMAIN="${MINIO_REPLICA_1_STORAGE_DOMAIN:-dr1-storage.wise-eat.com}"
MINIO_REPLICA_2_STORAGE_DOMAIN="${MINIO_REPLICA_2_STORAGE_DOMAIN:-dr2-storage.wise-eat.com}"
MINIO_REPLICA_1_API_PORT="${MINIO_REPLICA_1_API_PORT:-9002}"
MINIO_REPLICA_2_API_PORT="${MINIO_REPLICA_2_API_PORT:-9004}"

command -v nginx >/dev/null 2>&1 || die "nginx requis — sudo ./install.sh nginx"
systemctl is-active nginx >/dev/null 2>&1 || die "nginx inactif — sudo ./install.sh nginx"

install_minio_replica_storage_site() {
  local domain="$1"
  local port="$2"

  log "=== MinIO réplica nginx ${domain} → 127.0.0.1:${port} ==="
  STUNNEL_TLS_EMAIL="${STUNNEL_TLS_EMAIL:-}" \
    MINIO_STORAGE_DOMAIN="${domain}" \
    MINIO_BACKEND_PORT="${port}" \
    bash "${SCRIPT_DIR}/install-minio-storage.sh"

  if cert_exists "${domain}"; then
    MINIO_STORAGE_DOMAIN="${domain}" \
      MINIO_BACKEND_PORT="${port}" \
      bash "${SCRIPT_DIR}/enable-minio-storage-ssl.sh"
    log "HTTPS actif : https://${domain}/"
    return 0
  fi

  [[ -n "${STUNNEL_TLS_EMAIL:-}" ]] || \
    die "Certificat absent pour ${domain} — relancer avec STUNNEL_TLS_EMAIL=help@wise-eat.com"

  issue_le_cert "${domain}"
  MINIO_STORAGE_DOMAIN="${domain}" \
    MINIO_BACKEND_PORT="${port}" \
    bash "${SCRIPT_DIR}/enable-minio-storage-ssl.sh"
  log "Certificat LE émis — https://${domain}/"
}

install_minio_replica_storage_site "${MINIO_REPLICA_1_STORAGE_DOMAIN}" "${MINIO_REPLICA_1_API_PORT}"
install_minio_replica_storage_site "${MINIO_REPLICA_2_STORAGE_DOMAIN}" "${MINIO_REPLICA_2_API_PORT}"

log "Réplicas MinIO publics TLS OK"
log "Vérification : curl -I https://${MINIO_REPLICA_1_STORAGE_DOMAIN}/wise-eat/"
