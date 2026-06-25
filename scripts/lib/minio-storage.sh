#!/usr/bin/env bash
# Volume MinIO (25 Go par défaut) — loop ext4 ou montage existant.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Répertoire monté pour les objets S3 (bind-mount Docker).
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}"
MINIO_DATA_ROOT="${MINIO_DATA_ROOT:-/var/lib/wise-eat}"
MINIO_LOOP_FILE="${MINIO_LOOP_FILE:-${MINIO_DATA_ROOT}/minio-data.img}"
MINIO_STORAGE_GB="${MINIO_STORAGE_GB:-25}"

minio_data_mount_active() {
  mountpoint -q "${MINIO_DATA_DIR}" 2>/dev/null
}

minio_data_has_objects() {
  local legacy="${MINIO_DIR}/data"
  if [[ -d "${legacy}" ]] && [[ -n "$(ls -A "${legacy}" 2>/dev/null || true)" ]]; then
    return 0
  fi
  if [[ -d "${MINIO_DATA_DIR}" ]] && [[ -n "$(ls -A "${MINIO_DATA_DIR}" 2>/dev/null || true)" ]]; then
    return 0
  fi
  return 1
}

migrate_legacy_minio_data() {
  local legacy="${MINIO_DIR}/data"
  if [[ ! -d "${legacy}" ]] || [[ -z "$(ls -A "${legacy}" 2>/dev/null || true)" ]]; then
    return 0
  fi
  if [[ "$(readlink -f "${legacy}" 2>/dev/null || echo "${legacy}")" == "$(readlink -f "${MINIO_DATA_DIR}")" ]]; then
    return 0
  fi
  log "Migration données MinIO ${legacy} → ${MINIO_DATA_DIR}"
  mkdir -p "${MINIO_DATA_DIR}"
  rsync -a "${legacy}/" "${MINIO_DATA_DIR}/"
  mv "${legacy}" "${legacy}.migrated.$(date +%Y%m%d%H%M%S)"
}

ensure_minio_fstab_entry() {
  local img="$1" mount="$2"
  if grep -qF "${img}" /etc/fstab 2>/dev/null; then
    return 0
  fi
  echo "${img} ${mount} ext4 loop,noatime,nofail 0 2" >> /etc/fstab
  log "fstab : ${img} → ${mount}"
}

ensure_minio_data_volume() {
  require_root
  apt install -y e2fsprogs util-linux rsync 2>/dev/null || true

  # Chemin relatif (dev local) — pas de loop 25G.
  if [[ "${MINIO_DATA_DIR}" != /* ]]; then
    MINIO_DATA_DIR="${MINIO_DIR}/${MINIO_DATA_DIR#./}"
    mkdir -p "${MINIO_DATA_DIR}"
    chown -R 1000:1000 "${MINIO_DATA_DIR}" 2>/dev/null || true
    log "Volume MinIO local : ${MINIO_DATA_DIR}"
    return 0
  fi

  mkdir -p "${MINIO_DATA_ROOT}"

  # Montage déjà actif (partition VPS dédiée ou loop précédent).
  if minio_data_mount_active; then
    chown -R 1000:1000 "${MINIO_DATA_DIR}" 2>/dev/null || true
    migrate_legacy_minio_data
    log "Volume MinIO actif : ${MINIO_DATA_DIR} ($(df -h "${MINIO_DATA_DIR}" | awk 'NR==2{print $2" utilisés "$3" ("$5")"}'))"
    return 0
  fi

  # Bloc dédié optionnel (ex. /dev/sdb1).
  if [[ -n "${MINIO_DATA_DEVICE:-}" ]] && [[ -b "${MINIO_DATA_DEVICE}" ]]; then
    mkdir -p "${MINIO_DATA_DIR}"
    if ! blkid "${MINIO_DATA_DEVICE}" >/dev/null 2>&1; then
      log "Format ${MINIO_DATA_DEVICE} (ext4, label wise-eat-minio)"
      mkfs.ext4 -F -L wise-eat-minio "${MINIO_DATA_DEVICE}"
    fi
    if ! grep -qF "${MINIO_DATA_DEVICE}" /etc/fstab 2>/dev/null; then
      echo "${MINIO_DATA_DEVICE} ${MINIO_DATA_DIR} ext4 noatime,nofail 0 2" >> /etc/fstab
    fi
    mount -a
    chown -R 1000:1000 "${MINIO_DATA_DIR}" 2>/dev/null || true
    migrate_legacy_minio_data
    log "Volume MinIO (bloc) : ${MINIO_DATA_DEVICE} → ${MINIO_DATA_DIR}"
    return 0
  fi

  # Fichier loop 25 Go (défaut).
  if [[ ! -f "${MINIO_LOOP_FILE}" ]]; then
    log "Création volume MinIO ${MINIO_STORAGE_GB}G → ${MINIO_LOOP_FILE}"
    truncate -s "${MINIO_STORAGE_GB}G" "${MINIO_LOOP_FILE}"
    mkfs.ext4 -F -L wise-eat-minio "${MINIO_LOOP_FILE}"
  fi

  mkdir -p "${MINIO_DATA_DIR}"
  mount -o loop,noatime "${MINIO_LOOP_FILE}" "${MINIO_DATA_DIR}" 2>/dev/null || mount "${MINIO_DATA_DIR}"
  ensure_minio_fstab_entry "${MINIO_LOOP_FILE}" "${MINIO_DATA_DIR}"
  chown -R 1000:1000 "${MINIO_DATA_DIR}" 2>/dev/null || true
  migrate_legacy_minio_data

  log "Volume MinIO ${MINIO_STORAGE_GB}G monté : ${MINIO_DATA_DIR} ($(df -h "${MINIO_DATA_DIR}" | awk 'NR==2{print $2" total, "$3" utilisés"}'))"
}

persist_minio_env_paths() {
  local env_file="${MINIO_ENV}"
  [[ -f "${env_file}" ]] || return 0

  for pair in \
    "MINIO_DATA_DIR=${MINIO_DATA_DIR}" \
    "MINIO_STORAGE_GB=${MINIO_STORAGE_GB}" \
    "MINIO_STORAGE_DOMAIN=${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}" \
    "MINIO_CONSOLE_DOMAIN=${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}" \
    "MINIO_BACKUP_DIR=${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio}"; do
    local key="${pair%%=*}" val="${pair#*=}"
    if grep -q "^${key}=" "${env_file}"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${env_file}"
    else
      echo "${key}=${val}" >> "${env_file}"
    fi
  done

  local server_url="https://${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}"
  local console_url="https://${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}"
  if grep -q '^MINIO_SERVER_URL=' "${env_file}"; then
    sed -i "s|^MINIO_SERVER_URL=.*|MINIO_SERVER_URL=${server_url}|" "${env_file}"
  else
    echo "MINIO_SERVER_URL=${server_url}" >> "${env_file}"
  fi
  if grep -q '^MINIO_BROWSER_REDIRECT_URL=' "${env_file}"; then
    sed -i "s|^MINIO_BROWSER_REDIRECT_URL=.*|MINIO_BROWSER_REDIRECT_URL=${console_url}|" "${env_file}"
  else
    echo "MINIO_BROWSER_REDIRECT_URL=${console_url}" >> "${env_file}"
  fi
}
