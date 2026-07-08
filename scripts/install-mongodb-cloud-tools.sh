#!/usr/bin/env bash
# Installe gcloud + aws CLI pour les uploads MongoDB cloud.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

log "Installation outils cloud backup MongoDB…"

if ! command -v aws >/dev/null 2>&1; then
  apt update -qq
  apt install -y awscli 2>/dev/null || apt install -y aws-cli 2>/dev/null || {
    warn "awscli absent des dépôts — essai pip"
    apt install -y python3-pip
    pip3 install --break-system-packages awscli 2>/dev/null || pip3 install awscli
  }
fi

if ! command -v gcloud >/dev/null 2>&1 && ! command -v gsutil >/dev/null 2>&1; then
  if ! command -v snap >/dev/null 2>&1; then
    apt install -y snapd
  fi
  if snap install google-cloud-cli --classic 2>/dev/null; then
    log "google-cloud-cli installé via snap"
  else
    log "Tentative apt google-cloud-cli…"
    apt install -y apt-transport-https ca-certificates gnupg curl
    if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
      curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-cli.list
    apt update -qq
    apt install -y google-cloud-cli
  fi
fi

echo ""
echo "Versions installées :"
command -v gcloud >/dev/null 2>&1 && gcloud version | head -3 || true
command -v gsutil >/dev/null 2>&1 && gsutil version -l | head -1 || true
command -v aws >/dev/null 2>&1 && aws --version || true

log "Ensuite : sudo ./scripts/mongodb-backup.sh preflight"
