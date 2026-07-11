#!/usr/bin/env bash
# Volume Neo4j (5 Go par défaut) — loop ext4 ou montage existant.
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NEO4J_DIR="${NEO4J_DIR:-${WISE_EAT_ROOT}/neo4j}"
NEO4J_ENV="${NEO4J_ENV:-${NEO4J_DIR}/.env.neo4j}"
NEO4J_DATA_DIR="${NEO4J_DATA_DIR:-/var/lib/wise-eat/neo4j}"
NEO4J_DATA_ROOT="${NEO4J_DATA_ROOT:-/var/lib/wise-eat}"
NEO4J_LOOP_FILE="${NEO4J_LOOP_FILE:-${NEO4J_DATA_ROOT}/neo4j-data.img}"
NEO4J_STORAGE_GB="${NEO4J_STORAGE_GB:-5}"

neo4j_data_mount_active() {
  mountpoint -q "${NEO4J_DATA_DIR}" 2>/dev/null
}

ensure_neo4j_fstab_entry() {
  local img="$1" mount="$2"
  if grep -qF "${img}" /etc/fstab 2>/dev/null; then
    return 0
  fi
  echo "${img} ${mount} ext4 loop,noatime,nofail 0 2" >> /etc/fstab
  log "fstab : ${img} → ${mount}"
}

ensure_neo4j_data_dirs() {
  mkdir -p \
    "${NEO4J_DATA_DIR}/data" \
    "${NEO4J_DATA_DIR}/logs" \
    "${NEO4J_DATA_DIR}/import" \
    "${NEO4J_DATA_DIR}/plugins"
  # Image neo4j officielle : UID 7474
  chown -R 7474:7474 "${NEO4J_DATA_DIR}" 2>/dev/null || true
}

ensure_neo4j_data_volume() {
  require_root
  apt install -y e2fsprogs util-linux 2>/dev/null || true

  if [[ "${NEO4J_DATA_DIR}" != /* ]]; then
    NEO4J_DATA_DIR="${NEO4J_DIR}/${NEO4J_DATA_DIR#./}"
    ensure_neo4j_data_dirs
    log "Volume Neo4j local : ${NEO4J_DATA_DIR}"
    return 0
  fi

  mkdir -p "${NEO4J_DATA_ROOT}"

  if neo4j_data_mount_active; then
    ensure_neo4j_data_dirs
    log "Volume Neo4j actif : ${NEO4J_DATA_DIR} ($(df -h "${NEO4J_DATA_DIR}" | awk 'NR==2{print $2" utilisés "$3" ("$5")"}'))"
    return 0
  fi

  if [[ -n "${NEO4J_DATA_DEVICE:-}" ]] && [[ -b "${NEO4J_DATA_DEVICE}" ]]; then
    mkdir -p "${NEO4J_DATA_DIR}"
    if ! blkid "${NEO4J_DATA_DEVICE}" >/dev/null 2>&1; then
      log "Format ${NEO4J_DATA_DEVICE} (ext4, label wise-eat-neo4j)"
      mkfs.ext4 -F -L wise-eat-neo4j "${NEO4J_DATA_DEVICE}"
    fi
    if ! grep -qF "${NEO4J_DATA_DEVICE}" /etc/fstab 2>/dev/null; then
      echo "${NEO4J_DATA_DEVICE} ${NEO4J_DATA_DIR} ext4 noatime,nofail 0 2" >> /etc/fstab
    fi
    mount -a
    ensure_neo4j_data_dirs
    log "Volume Neo4j (bloc) : ${NEO4J_DATA_DEVICE} → ${NEO4J_DATA_DIR}"
    return 0
  fi

  if [[ ! -f "${NEO4J_LOOP_FILE}" ]]; then
    log "Création volume Neo4j ${NEO4J_STORAGE_GB}G → ${NEO4J_LOOP_FILE}"
    truncate -s "${NEO4J_STORAGE_GB}G" "${NEO4J_LOOP_FILE}"
    mkfs.ext4 -F -L wise-eat-neo4j "${NEO4J_LOOP_FILE}"
  fi

  mkdir -p "${NEO4J_DATA_DIR}"
  mount -o loop,noatime "${NEO4J_LOOP_FILE}" "${NEO4J_DATA_DIR}" 2>/dev/null || mount "${NEO4J_DATA_DIR}"
  ensure_neo4j_fstab_entry "${NEO4J_LOOP_FILE}" "${NEO4J_DATA_DIR}"
  ensure_neo4j_data_dirs

  log "Volume Neo4j ${NEO4J_STORAGE_GB}G monté : ${NEO4J_DATA_DIR} ($(df -h "${NEO4J_DATA_DIR}" | awk 'NR==2{print $2" total, "$3" utilisés"}'))"
}

persist_neo4j_env_paths() {
  [[ -f "${NEO4J_ENV}" ]] || return 0
  if grep -q '^NEO4J_DATA_DIR=' "${NEO4J_ENV}"; then
    sed -i "s|^NEO4J_DATA_DIR=.*|NEO4J_DATA_DIR=${NEO4J_DATA_DIR}|" "${NEO4J_ENV}"
  else
    echo "NEO4J_DATA_DIR=${NEO4J_DATA_DIR}" >> "${NEO4J_ENV}"
  fi
  if grep -q '^NEO4J_STORAGE_GB=' "${NEO4J_ENV}"; then
    sed -i "s|^NEO4J_STORAGE_GB=.*|NEO4J_STORAGE_GB=${NEO4J_STORAGE_GB}|" "${NEO4J_ENV}"
  else
    echo "NEO4J_STORAGE_GB=${NEO4J_STORAGE_GB}" >> "${NEO4J_ENV}"
  fi
}
