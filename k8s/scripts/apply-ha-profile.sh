#!/usr/bin/env bash
# Rollback / apply profil HA (réplicas Redis/EMQX/MinIO/Memcached + HPA base max 5/3).
# Réservé VPS ≥16 Go ou multi-nœuds — voir k8s/VPS_SCALING.md.
#
# Usage :
#   sudo k8s/scripts/apply-ha-profile.sh
#   sudo ./install.sh apply-ha
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
OVERLAY="${INFRA_ROOT}/k8s/overlays/ha"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(k3s kubectl)
fi

# Remettre les Deployments HA à 1 après apply (bases déclarent déjà replicas:1).
HA_SCALE_ONE=(
  redis-cache-replica-1
  redis-cache-replica-2
  redis-bullmq-replica-1
  redis-bullmq-replica-2
  memcached-replica-1
  memcached-replica-2
  emqx-2
  emqx-3
  minio-replica-1
  minio-replica-2
)

warn "Profil HA — ne pas utiliser sur Hostinger KVM 2 (2 vCPU / 8 Go)"
log "kubectl apply -k ${OVERLAY}"
"${KUBECTL[@]}" apply -k "${OVERLAY}"

log "Scale replicas=1 sur Deployments HA"
for dep in "${HA_SCALE_ONE[@]}"; do
  if "${KUBECTL[@]}" -n "${NAMESPACE}" get "deploy/${dep}" >/dev/null 2>&1; then
    "${KUBECTL[@]}" -n "${NAMESPACE}" scale "deploy/${dep}" --replicas=1
  fi
done

# ConfigMaps HA ont les ports réplicas — restart apps pour les recharger.
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout restart deploy/africa-meals-api deploy/africa-meals-ws 2>/dev/null || true

log "HPA (max API 5 / WS 3 attendus)"
"${KUBECTL[@]}" -n "${NAMESPACE}" get hpa -o wide || true
log "Si MinIO SR souhaitée : sudo ./install.sh repair-minio-site-replication-k8s"
log "Doc : k8s/VPS_SCALING.md"
