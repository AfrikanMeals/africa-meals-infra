#!/usr/bin/env bash
# Volume MongoDB (5 Go par défaut) — loop ext4 ou montage existant.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MONGODB_DIR="${MONGODB_DIR:-${WISE_EAT_ROOT}/mongodb}"
MONGODB_ENV="${MONGODB_ENV:-${MONGODB_DIR}/.env.mongodb}"
MONGO_DATA_DIR="${MONGO_DATA_DIR:-/var/lib/wise-eat/mongodb}"
MONGO_DATA_ROOT="${MONGO_DATA_ROOT:-/var/lib/wise-eat}"
MONGO_LOOP_FILE="${MONGO_LOOP_FILE:-${MONGO_DATA_ROOT}/mongodb-data.img}"
MONGO_STORAGE_GB="${MONGO_STORAGE_GB:-5}"

mongo_data_mount_active() {
  mountpoint -q "${MONGO_DATA_DIR}" 2>/dev/null
}

ensure_mongo_fstab_entry() {
  local img="$1" mount="$2"
  if grep -qF "${img}" /etc/fstab 2>/dev/null; then
    return 0
  fi
  echo "${img} ${mount} ext4 loop,noatime,nofail 0 2" >> /etc/fstab
  log "fstab : ${img} → ${mount}"
}

ensure_mongodb_data_volume() {
  require_root
  apt install -y e2fsprogs util-linux 2>/dev/null || true

  if [[ "${MONGO_DATA_DIR}" != /* ]]; then
    MONGO_DATA_DIR="${MONGODB_DIR}/${MONGO_DATA_DIR#./}"
    mkdir -p "${MONGO_DATA_DIR}/data-mongo-1" "${MONGO_DATA_DIR}/data-mongo-2" "${MONGO_DATA_DIR}/data-mongo-3"
    chown -R 999:999 "${MONGO_DATA_DIR}" 2>/dev/null || true
    log "Volume MongoDB local : ${MONGO_DATA_DIR}"
    return 0
  fi

  mkdir -p "${MONGO_DATA_ROOT}"

  if mongo_data_mount_active; then
    mkdir -p "${MONGO_DATA_DIR}/data-mongo-1" "${MONGO_DATA_DIR}/data-mongo-2" "${MONGO_DATA_DIR}/data-mongo-3"
    chown -R 999:999 "${MONGO_DATA_DIR}" 2>/dev/null || true
    log "Volume MongoDB actif : ${MONGO_DATA_DIR} ($(df -h "${MONGO_DATA_DIR}" | awk 'NR==2{print $2" utilisés "$3" ("$5")"}'))"
    return 0
  fi

  if [[ -n "${MONGO_DATA_DEVICE:-}" ]] && [[ -b "${MONGO_DATA_DEVICE}" ]]; then
    mkdir -p "${MONGO_DATA_DIR}"
    if ! blkid "${MONGO_DATA_DEVICE}" >/dev/null 2>&1; then
      log "Format ${MONGO_DATA_DEVICE} (ext4, label wise-eat-mongodb)"
      mkfs.ext4 -F -L wise-eat-mongodb "${MONGO_DATA_DEVICE}"
    fi
    if ! grep -qF "${MONGO_DATA_DEVICE}" /etc/fstab 2>/dev/null; then
      echo "${MONGO_DATA_DEVICE} ${MONGO_DATA_DIR} ext4 noatime,nofail 0 2" >> /etc/fstab
    fi
    mount -a
    mkdir -p "${MONGO_DATA_DIR}/data-mongo-1" "${MONGO_DATA_DIR}/data-mongo-2" "${MONGO_DATA_DIR}/data-mongo-3"
    chown -R 999:999 "${MONGO_DATA_DIR}" 2>/dev/null || true
    log "Volume MongoDB (bloc) : ${MONGO_DATA_DEVICE} → ${MONGO_DATA_DIR}"
    return 0
  fi

  if [[ ! -f "${MONGO_LOOP_FILE}" ]]; then
    log "Création volume MongoDB ${MONGO_STORAGE_GB}G → ${MONGO_LOOP_FILE}"
    truncate -s "${MONGO_STORAGE_GB}G" "${MONGO_LOOP_FILE}"
    mkfs.ext4 -F -L wise-eat-mongodb "${MONGO_LOOP_FILE}"
  fi

  mkdir -p "${MONGO_DATA_DIR}"
  mount -o loop,noatime "${MONGO_LOOP_FILE}" "${MONGO_DATA_DIR}" 2>/dev/null || mount "${MONGO_DATA_DIR}"
  ensure_mongo_fstab_entry "${MONGO_LOOP_FILE}" "${MONGO_DATA_DIR}"
  mkdir -p "${MONGO_DATA_DIR}/data-mongo-1" "${MONGO_DATA_DIR}/data-mongo-2" "${MONGO_DATA_DIR}/data-mongo-3"
  chown -R 999:999 "${MONGO_DATA_DIR}" 2>/dev/null || true

  log "Volume MongoDB ${MONGO_STORAGE_GB}G monté : ${MONGO_DATA_DIR} ($(df -h "${MONGO_DATA_DIR}" | awk 'NR==2{print $2" total, "$3" utilisés"}'))"
}

ensure_mongodb_swap() {
  local swap_size="${MONGO_SWAP_SIZE_GB:-2}"
  if swapon --show 2>/dev/null | grep -q .; then
    log "Swap déjà actif ($(swapon --show | awk 'NR==2{print $3}'))"
    return 0
  fi
  local swapfile="/swapfile-mongodb"
  if [[ -f "${swapfile}" ]]; then
    swapon "${swapfile}" 2>/dev/null || true
    if swapon --show 2>/dev/null | grep -q "${swapfile}"; then
      log "Swap réactivé : ${swapfile}"
      return 0
    fi
  fi
  log "Création swap ${swap_size}G (${swapfile})"
  fallocate -l "${swap_size}G" "${swapfile}" 2>/dev/null || dd if=/dev/zero of="${swapfile}" bs=1M count=$((swap_size * 1024)) status=progress
  chmod 600 "${swapfile}"
  mkswap "${swapfile}"
  swapon "${swapfile}"
  if ! grep -qF "${swapfile}" /etc/fstab 2>/dev/null; then
    echo "${swapfile} none swap sw 0 0" >> /etc/fstab
  fi
  log "Swap activé : ${swap_size}G"
}

persist_mongodb_env_paths() {
  local env_file="${MONGODB_ENV}"
  [[ -f "${env_file}" ]] || return 0

  for pair in \
    "MONGO_DATA_DIR=${MONGO_DATA_DIR}" \
    "MONGO_STORAGE_GB=${MONGO_STORAGE_GB}" \
    "MONGO_DATA_1=${MONGO_DATA_DIR}/data-mongo-1" \
    "MONGO_DATA_2=${MONGO_DATA_DIR}/data-mongo-2" \
    "MONGO_DATA_3=${MONGO_DATA_DIR}/data-mongo-3" \
    "MONGO_TLS_DOMAIN=${MONGO_TLS_DOMAIN:-db.wise-eat.com}" \
    "MONGO_ADMIN_DOMAIN=${MONGO_ADMIN_DOMAIN:-data.wise-eat.com}" \
    "MONGO_BACKUP_DIR=${MONGO_BACKUP_DIR:-/var/backups/wise-eat-mongodb}" \
    "MONGO_DBGATE_PORT=${MONGO_DBGATE_PORT:-8081}" \
    "MONGO_DBGATE_DATA=${MONGODB_DIR}/data-dbgate"; do
    local key="${pair%%=*}" val="${pair#*=}"
    if grep -q "^${key}=" "${env_file}"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${env_file}"
    else
      echo "${key}=${val}" >> "${env_file}"
    fi
  done
}
