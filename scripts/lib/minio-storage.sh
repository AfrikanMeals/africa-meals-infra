#!/usr/bin/env bash
# Volume MinIO (10 Go par défaut) — loop ext4 ou montage existant.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Répertoire monté pour les objets S3 (bind-mount Docker).
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/wise-eat/minio}"
MINIO_DATA_ROOT="${MINIO_DATA_ROOT:-/var/lib/wise-eat}"
MINIO_LOOP_FILE="${MINIO_LOOP_FILE:-${MINIO_DATA_ROOT}/minio-data.img}"
MINIO_STORAGE_GB="${MINIO_STORAGE_GB:-10}"

minio_data_mount_active() {
  mountpoint -q "${MINIO_DATA_DIR}" 2>/dev/null
}

minio_data_mount_active_for() {
  mountpoint -q "${1}" 2>/dev/null
}

minio_container_for_data_dir() {
  case "${1}" in
    */minio-replica-1) echo "wise-eat-minio-replica-1" ;;
    */minio-replica-2) echo "wise-eat-minio-replica-2" ;;
    *) echo "wise-eat-minio" ;;
  esac
}

minio_loop_file_size_gb() {
  local img="$1"
  [[ -f "${img}" ]] || return 1
  stat -c '%s' "${img}" | awk '{printf "%d\n", ($1 + 1073741823) / 1073741824}'
}

# Réduit un fichier loop ext4 existant vers target_gb si l'espace utilisé le permet.
shrink_minio_loop_volume_if_needed() {
  local data_dir="$1"
  local loop_file="$2"
  local target_gb="$3"

  [[ -f "${loop_file}" ]] || return 0
  [[ "${data_dir}" == /* ]] || return 0
  if [[ -n "${MINIO_DATA_DEVICE:-}" ]] && [[ -b "${MINIO_DATA_DEVICE}" ]]; then
    return 0
  fi

  local current_gb
  current_gb="$(minio_loop_file_size_gb "${loop_file}")"
  [[ "${current_gb}" -gt "${target_gb}" ]] || return 0

  local used_bytes target_bytes margin_bytes
  if minio_data_mount_active_for "${data_dir}"; then
    used_bytes="$(df -B1 "${data_dir}" | awk 'NR==2{print $3}')"
  else
    mkdir -p "${data_dir}"
    mount -o loop,noatime "${loop_file}" "${data_dir}"
    used_bytes="$(df -B1 "${data_dir}" | awk 'NR==2{print $3}')"
    umount "${data_dir}"
  fi

  target_bytes=$(( target_gb * 1024 * 1024 * 1024 ))
  margin_bytes=$(( 512 * 1024 * 1024 ))
  if (( used_bytes + margin_bytes > target_bytes )); then
    warn "Volume MinIO ${data_dir} : $(numfmt --to=iec-i --suffix=B "${used_bytes}" 2>/dev/null || echo "${used_bytes} o") utilisés > ${target_gb}G cible — réduction ignorée (données préservées)"
    return 0
  fi

  log "Réduction volume MinIO ${loop_file} : ${current_gb}G → ${target_gb}G (données préservées)"

  local container
  container="$(minio_container_for_data_dir "${data_dir}")"
  if docker ps -q -f "name=^${container}$" 2>/dev/null | grep -q .; then
    log "Arrêt ${container} pour réduction volume"
    docker stop "${container}" || true
  fi

  if minio_data_mount_active_for "${data_dir}"; then
    umount "${data_dir}"
  fi

  local loop_dev=""
  cleanup_loop() {
    [[ -n "${loop_dev}" ]] && losetup -d "${loop_dev}" 2>/dev/null || true
  }
  trap cleanup_loop EXIT

  loop_dev="$(losetup --find --show "${loop_file}")"
  e2fsck -fy "${loop_dev}"
  resize2fs "${loop_dev}" "${target_gb}G"
  truncate -s "${target_gb}G" "${loop_file}"
  losetup -d "${loop_dev}"
  loop_dev=""
  trap - EXIT

  mount -o loop,noatime "${loop_file}" "${data_dir}"
  chown -R 1000:1000 "${data_dir}" 2>/dev/null || true

  if docker ps -aq -f "name=^${container}$" 2>/dev/null | grep -q .; then
    docker start "${container}" 2>/dev/null || true
  fi

  log "Volume MinIO réduit : ${data_dir} (${target_gb}G, $(df -h "${data_dir}" | awk 'NR==2{print $3" utilisés"}'))"
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

  # Chemin relatif (dev local) — pas de loop dédié.
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
    if [[ -f "${MINIO_LOOP_FILE}" ]] && [[ -z "${MINIO_DATA_DEVICE:-}" ]]; then
      shrink_minio_loop_volume_if_needed "${MINIO_DATA_DIR}" "${MINIO_LOOP_FILE}" "${MINIO_STORAGE_GB}"
    fi
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

  # Fichier loop (défaut MINIO_STORAGE_GB Go).
  if [[ ! -f "${MINIO_LOOP_FILE}" ]]; then
    log "Création volume MinIO ${MINIO_STORAGE_GB}G → ${MINIO_LOOP_FILE}"
    truncate -s "${MINIO_STORAGE_GB}G" "${MINIO_LOOP_FILE}"
    mkfs.ext4 -F -L wise-eat-minio "${MINIO_LOOP_FILE}"
  else
    shrink_minio_loop_volume_if_needed "${MINIO_DATA_DIR}" "${MINIO_LOOP_FILE}" "${MINIO_STORAGE_GB}"
  fi

  mkdir -p "${MINIO_DATA_DIR}"
  mount -o loop,noatime "${MINIO_LOOP_FILE}" "${MINIO_DATA_DIR}" 2>/dev/null || mount "${MINIO_DATA_DIR}"
  ensure_minio_fstab_entry "${MINIO_LOOP_FILE}" "${MINIO_DATA_DIR}"
  chown -R 1000:1000 "${MINIO_DATA_DIR}" 2>/dev/null || true
  migrate_legacy_minio_data

  log "Volume MinIO ${MINIO_STORAGE_GB}G monté : ${MINIO_DATA_DIR} ($(df -h "${MINIO_DATA_DIR}" | awk 'NR==2{print $2" total, "$3" utilisés"}'))"
}

ensure_minio_replica_data_volume() {
  local replica_num="$1"
  local data_dir_var="MINIO_REPLICA_${replica_num}_DATA_DIR"
  local loop_var="MINIO_REPLICA_${replica_num}_LOOP_FILE"
  local gb_var="MINIO_REPLICA_${replica_num}_STORAGE_GB"
  local data_dir_default="/var/lib/wise-eat/minio-replica-${replica_num}"
  local data_dir="${!data_dir_var:-${data_dir_default}}"
  local loop_default="${MINIO_DATA_ROOT:-/var/lib/wise-eat}/minio-replica-${replica_num}-data.img"
  local loop_file="${!loop_var:-${loop_default}}"
  local storage_gb="${!gb_var:-${MINIO_STORAGE_GB:-10}}"

  MINIO_DATA_DIR="${data_dir}" \
    MINIO_LOOP_FILE="${loop_file}" \
    MINIO_STORAGE_GB="${storage_gb}" \
    ensure_minio_data_volume

  export "${data_dir_var}=${data_dir}"
}

persist_minio_env_paths() {
  local env_file="${MINIO_ENV}"
  [[ -f "${env_file}" ]] || return 0

  for pair in \
    "MINIO_DATA_DIR=${MINIO_DATA_DIR}" \
    "MINIO_STORAGE_GB=${MINIO_STORAGE_GB}" \
    "MINIO_STORAGE_DOMAIN=${MINIO_STORAGE_DOMAIN:-storage.wise-eat.com}" \
    "MINIO_CONSOLE_DOMAIN=${MINIO_CONSOLE_DOMAIN:-cdn.wise-eat.com}" \
    "MINIO_BACKUP_DIR=${MINIO_BACKUP_DIR:-/var/backups/wise-eat-minio}" \
    "MINIO_REPLICA_1_DATA_DIR=${MINIO_REPLICA_1_DATA_DIR:-/var/lib/wise-eat/minio-replica-1}" \
    "MINIO_REPLICA_2_DATA_DIR=${MINIO_REPLICA_2_DATA_DIR:-/var/lib/wise-eat/minio-replica-2}" \
    "MINIO_REPLICA_1_API_PORT=${MINIO_REPLICA_1_API_PORT:-9002}" \
    "MINIO_REPLICA_2_API_PORT=${MINIO_REPLICA_2_API_PORT:-9004}"; do
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
