#!/usr/bin/env bash
# Swap hôte + swappiness — VPS Wise Eat (8 Go RAM, stack Docker partagé).
# Chaque conteneur : mem_limit (RAM) + memswap_limit (RAM + swap autorisé).

ensure_vps_swap() {
  local swap_size="${VPS_SWAP_SIZE_GB:-2}"
  local swapfile="${VPS_SWAP_FILE:-/swapfile}"

  if swapon --show 2>/dev/null | grep -q .; then
    log "Swap hôte actif ($(swapon --show | awk 'NR==2{print $1" "$3}'))"
    return 0
  fi

  if [[ -f "${swapfile}" ]]; then
    swapon "${swapfile}" 2>/dev/null || true
    if swapon --show 2>/dev/null | grep -qF "${swapfile}"; then
      log "Swap réactivé : ${swapfile}"
      return 0
    fi
  fi

  log "Création swap ${swap_size}G (${swapfile})"
  fallocate -l "${swap_size}G" "${swapfile}" 2>/dev/null \
    || dd if=/dev/zero of="${swapfile}" bs=1M count=$((swap_size * 1024)) status=progress
  chmod 600 "${swapfile}"
  mkswap "${swapfile}"
  swapon "${swapfile}"
  if ! grep -qF "${swapfile}" /etc/fstab 2>/dev/null; then
    echo "${swapfile} none swap sw 0 0" >> /etc/fstab
  fi
  log "Swap activé : ${swap_size}G"
}

tune_vps_swappiness() {
  local swappiness="${VPS_SWAPPINESS:-40}"
  local conf="/etc/sysctl.d/99-wise-eat-swappiness.conf"

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    return 0
  fi

  sysctl -w "vm.swappiness=${swappiness}" >/dev/null 2>&1 || true
  if [[ ! -f "${conf}" ]] || ! grep -qF "vm.swappiness=${swappiness}" "${conf}" 2>/dev/null; then
    echo "vm.swappiness=${swappiness}" > "${conf}"
    log "vm.swappiness=${swappiness} (persistant ${conf})"
  fi
}

ensure_vps_memory_tuning() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0
  ensure_vps_swap
  tune_vps_swappiness
}
