#!/usr/bin/env bash
# Volume Matomo (5 Go par défaut) — loop ext4 ou montage existant.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MATOMO_DIR="${MATOMO_DIR:-${WISE_EAT_ROOT}/matomo}"
MATOMO_ENV="${MATOMO_ENV:-${MATOMO_DIR}/.env.matomo}"
MATOMO_DATA_DIR="${MATOMO_DATA_DIR:-/var/lib/wise-eat/matomo}"
MATOMO_DATA_ROOT="${MATOMO_DATA_ROOT:-/var/lib/wise-eat}"
MATOMO_LOOP_FILE="${MATOMO_LOOP_FILE:-${MATOMO_DATA_ROOT}/matomo-data.img}"
MATOMO_STORAGE_GB="${MATOMO_STORAGE_GB:-5}"

matomo_data_mount_active() {
  mountpoint -q "${MATOMO_DATA_DIR}" 2>/dev/null
}

ensure_matomo_fstab_entry() {
  local img="$1" mount="$2"
  if grep -qF "${img}" /etc/fstab 2>/dev/null; then
    return 0
  fi
  echo "${img} ${mount} ext4 loop,noatime,nofail 0 2" >> /etc/fstab
  log "fstab : ${img} → ${mount}"
}

ensure_matomo_data_dirs() {
  mkdir -p "${MATOMO_DATA_DIR}/html" "${MATOMO_DATA_DIR}/db"
  chown -R 33:33 "${MATOMO_DATA_DIR}/html" 2>/dev/null || true
  chown -R 999:999 "${MATOMO_DATA_DIR}/db" 2>/dev/null || true
}

ensure_matomo_data_volume() {
  require_root
  apt install -y e2fsprogs util-linux 2>/dev/null || true

  if [[ "${MATOMO_DATA_DIR}" != /* ]]; then
    MATOMO_DATA_DIR="${MATOMO_DIR}/${MATOMO_DATA_DIR#./}"
    ensure_matomo_data_dirs
    log "Volume Matomo local : ${MATOMO_DATA_DIR}"
    return 0
  fi

  mkdir -p "${MATOMO_DATA_ROOT}"

  if matomo_data_mount_active; then
    ensure_matomo_data_dirs
    log "Volume Matomo actif : ${MATOMO_DATA_DIR} ($(df -h "${MATOMO_DATA_DIR}" | awk 'NR==2{print $2" utilisés "$3" ("$5")"}'))"
    return 0
  fi

  if [[ -n "${MATOMO_DATA_DEVICE:-}" ]] && [[ -b "${MATOMO_DATA_DEVICE}" ]]; then
    mkdir -p "${MATOMO_DATA_DIR}"
    if ! blkid "${MATOMO_DATA_DEVICE}" >/dev/null 2>&1; then
      log "Format ${MATOMO_DATA_DEVICE} (ext4, label wise-eat-matomo)"
      mkfs.ext4 -F -L wise-eat-matomo "${MATOMO_DATA_DEVICE}"
    fi
    if ! grep -qF "${MATOMO_DATA_DEVICE}" /etc/fstab 2>/dev/null; then
      echo "${MATOMO_DATA_DEVICE} ${MATOMO_DATA_DIR} ext4 noatime,nofail 0 2" >> /etc/fstab
    fi
    mount -a
    ensure_matomo_data_dirs
    log "Volume Matomo (bloc) : ${MATOMO_DATA_DEVICE} → ${MATOMO_DATA_DIR}"
    return 0
  fi

  if [[ ! -f "${MATOMO_LOOP_FILE}" ]]; then
    log "Création volume Matomo ${MATOMO_STORAGE_GB}G → ${MATOMO_LOOP_FILE}"
    truncate -s "${MATOMO_STORAGE_GB}G" "${MATOMO_LOOP_FILE}"
    mkfs.ext4 -F -L wise-eat-matomo "${MATOMO_LOOP_FILE}"
  fi

  mkdir -p "${MATOMO_DATA_DIR}"
  mount -o loop,noatime "${MATOMO_LOOP_FILE}" "${MATOMO_DATA_DIR}" 2>/dev/null || mount "${MATOMO_DATA_DIR}"
  ensure_matomo_fstab_entry "${MATOMO_LOOP_FILE}" "${MATOMO_DATA_DIR}"
  ensure_matomo_data_dirs

  log "Volume Matomo ${MATOMO_STORAGE_GB}G monté : ${MATOMO_DATA_DIR} ($(df -h "${MATOMO_DATA_DIR}" | awk 'NR==2{print $2" total, "$3" utilisés"}'))"
}

persist_matomo_env_paths() {
  [[ -f "${MATOMO_ENV}" ]] || return 0
  if grep -q '^MATOMO_DATA_DIR=' "${MATOMO_ENV}"; then
    sed -i "s|^MATOMO_DATA_DIR=.*|MATOMO_DATA_DIR=${MATOMO_DATA_DIR}|" "${MATOMO_ENV}"
  else
    echo "MATOMO_DATA_DIR=${MATOMO_DATA_DIR}" >> "${MATOMO_ENV}"
  fi
}
