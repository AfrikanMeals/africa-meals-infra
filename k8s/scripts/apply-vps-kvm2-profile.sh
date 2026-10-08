#!/usr/bin/env bash
# Applique le profil VPS Hostinger KVM 2 (2 vCPU / 8 Go) :
#   HPA API/WS max 2 · réplicas HA → 0 · EMQX seed unique · Neo4j heap réduit
#   ConfigMaps sans ports Redis/Memcached réplicas.
#
# Prérequis : k3s + namespace wise-eat déjà déployés.
# Usage :
#   sudo k8s/scripts/apply-vps-kvm2-profile.sh
#   sudo ./install.sh apply-vps-kvm2
#   DRY_RUN=1 sudo k8s/scripts/apply-vps-kvm2-profile.sh
#
# Rollback HA : sudo k8s/scripts/apply-ha-profile.sh (voir VPS_SCALING.md)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
OVERLAY="${INFRA_ROOT}/k8s/overlays/vps-kvm2"
DRY_RUN="${DRY_RUN:-0}"
MINIO_ENV="${MINIO_ENV:-${INFRA_ROOT}/minio/.env.minio}"
MC_IMAGE="${MINIO_MC_IMAGE:-minio/mc:RELEASE.2024-10-08T09-37-26Z}"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(k3s kubectl)
fi

# Deployments HA à forcer à 0 (filet si apply partiel / drift).
HA_SCALE_ZERO=(
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

log "Profil vps-kvm2 — dry-run kustomize"
"${KUBECTL[@]}" kustomize "${OVERLAY}" >/dev/null

if [[ "${DRY_RUN}" == "1" ]]; then
  log "DRY_RUN=1 — affichage kustomize uniquement (pas d'apply)"
  "${KUBECTL[@]}" kustomize "${OVERLAY}" | head -n 40
  echo "... (tronqué)"
  exit 0
fi

# 1. Désactiver MinIO site-replication si peers encore up (évite PutObject / SR errors).
disable_minio_site_replication() {
  local primary_ready
  primary_ready="$("${KUBECTL[@]}" -n "${NAMESPACE}" get deploy/minio -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${primary_ready}" != "1" ]]; then
    log "MinIO primary pas Ready — skip disable SR"
    return 0
  fi
  if [[ ! -f "${MINIO_ENV}" ]]; then
    warn "Pas de ${MINIO_ENV} — skip disable SR MinIO (à faire manuellement si SR active)"
    return 0
  fi
  set -a
  # shellcheck disable=SC1090
  source "${MINIO_ENV}"
  set +a
  : "${MINIO_ROOT_USER:?}"
  : "${MINIO_ROOT_PASSWORD:?}"

  log "Purge MinIO site-replication (primary only pour kvm2)"
  "${KUBECTL[@]}" -n "${NAMESPACE}" delete pod mc-sr-disable-kvm2 --ignore-not-found --wait=true >/dev/null 2>&1 || true
  # Job éphémère : mc admin replicate rm --all (peers absents = OK).
  "${KUBECTL[@]}" -n "${NAMESPACE}" run mc-sr-disable-kvm2 --restart=Never \
    --image="${MC_IMAGE}" \
    --env="MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
    --env="MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
    --command -- /bin/sh -c '
      set +e
      mc alias set primary http://minio.wise-eat.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
      mc admin replicate rm primary --all --force
      mc admin replicate info primary || true
    ' || true
  "${KUBECTL[@]}" -n "${NAMESPACE}" wait --for=condition=Ready pod/mc-sr-disable-kvm2 --timeout=60s 2>/dev/null || true
  sleep 5
  "${KUBECTL[@]}" -n "${NAMESPACE}" logs mc-sr-disable-kvm2 2>/dev/null || true
  "${KUBECTL[@]}" -n "${NAMESPACE}" delete pod mc-sr-disable-kvm2 --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

disable_minio_site_replication

# 2. Apply overlay déclaratif.
log "kubectl apply -k ${OVERLAY}"
"${KUBECTL[@]}" apply -k "${OVERLAY}"

# 3. Filet scale 0 (Deployments encore présents hors overlay drift).
log "Scale sécurité replicas=0 sur Deployments HA"
for dep in "${HA_SCALE_ZERO[@]}"; do
  if "${KUBECTL[@]}" -n "${NAMESPACE}" get "deploy/${dep}" >/dev/null 2>&1; then
    "${KUBECTL[@]}" -n "${NAMESPACE}" scale "deploy/${dep}" --replicas=0
  fi
done

# 4. Rollout apps (ConfigMap strip + HPA).
log "Restart API/WS pour recharger ConfigMaps (sans ports réplicas)"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout restart deploy/africa-meals-api deploy/africa-meals-ws deploy/emqx-1 deploy/neo4j 2>/dev/null || true
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/africa-meals-api --timeout=180s || warn "API rollout timeout"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/africa-meals-ws --timeout=180s || warn "WS rollout timeout"

# 5. Checks budget / HPA.
log "État HPA"
"${KUBECTL[@]}" -n "${NAMESPACE}" get hpa africa-meals-api africa-meals-ws -o wide || true

log "Deployments (replicas)"
"${KUBECTL[@]}" -n "${NAMESPACE}" get deploy \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas \
  --sort-by=.metadata.name || true

if "${KUBECTL[@]}" top node >/dev/null 2>&1; then
  log "kubectl top node / pods (metrics-server)"
  "${KUBECTL[@]}" top node || true
  "${KUBECTL[@]}" -n "${NAMESPACE}" top pods --sort-by=memory 2>/dev/null | head -n 25 || true
else
  warn "metrics-server indisponible — skip kubectl top"
fi

# Budget requests des pods Running (lecture humaine).
log "Budget requests pods Running (namespace ${NAMESPACE})"
"${KUBECTL[@]}" -n "${NAMESPACE}" get pods --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.resources.requests.cpu}{"/"}{.resources.requests.memory}{" "}{end}{"\n"}{end}' \
  2>/dev/null || true

log "Profil vps-kvm2 appliqué. Smoke : curl -sI https://apis.wise-eat.com/health ; curl -sI https://ws.wise-eat.com/api/health"
log "Doc : k8s/VPS_SCALING.md"

