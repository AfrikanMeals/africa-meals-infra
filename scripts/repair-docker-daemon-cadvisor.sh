#!/usr/bin/env bash
# Docker 29 + containerd-snapshotter (overlayfs) casse cAdvisor < v0.54.
# Désactive le snapshotter expérimental → retour overlay2 classique (redémarrage Docker requis).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
log "=== Compatibilité Docker ↔ cAdvisor (containerd-snapshotter) ==="

storage_driver="$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')"
log "Storage Driver actuel : ${storage_driver:-inconnu}"

if [[ "${storage_driver}" != "overlayfs" ]]; then
  log "Storage Driver ≠ overlayfs — essayer d'abord : sudo ./install.sh repair-cadvisor"
  exit 0
fi

DAEMON_JSON="/etc/docker/daemon.json"
backup="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
[[ -f "${DAEMON_JSON}" ]] && cp -a "${DAEMON_JSON}" "${backup}" && log "Sauvegarde → ${backup}"

python3 <<'PY'
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
data = {}
if path.exists():
    data = json.loads(path.read_text(encoding="utf-8"))
features = data.setdefault("features", {})
if features.get("containerd-snapshotter") is False:
    print("containerd-snapshotter déjà désactivé")
else:
    features["containerd-snapshotter"] = False
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print("Écrit containerd-snapshotter=false dans daemon.json")
PY

log "Redémarrage Docker (tous les conteneurs redémarrent via restart policy)…"
systemctl restart docker

for _ in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker info >/dev/null 2>&1 || die "Docker injoignable après restart"

new_driver="$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')"
log "Storage Driver après restart : ${new_driver:-?}"

log "Recréation cAdvisor…"
bash "${SCRIPT_DIR}/repair-cadvisor.sh"
