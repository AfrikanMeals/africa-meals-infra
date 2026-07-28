#!/usr/bin/env bash
# Répare / reconfigure la site-replication MinIO après cutover Docker → k8s.
#
# Problème typique : les endpoints restent `http://wise-eat-minio:9000` (DNS Docker
# mort) → peers injoignables → Access Denied / PutObject KO.
#
# Cible k8s (Services ClusterIP, joignables depuis les pods) :
#   minio.wise-eat.svc.cluster.local:9000
#   minio-replica-1.wise-eat.svc.cluster.local:9000
#   minio-replica-2.wise-eat.svc.cluster.local:9000
#
# Usage :
#   sudo ./repair-minio-site-replication-k8s.sh
#   sudo ./install.sh repair-minio-site-replication-k8s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${INFRA_ROOT}/scripts/lib/common.sh"

require_root

MINIO_ENV="${MINIO_ENV:-${INFRA_ROOT}/minio/.env.minio}"
NAMESPACE="${K8S_NAMESPACE:-wise-eat}"
MC_IMAGE="${MINIO_MC_IMAGE:-minio/mc:RELEASE.2024-10-08T09-37-26Z}"

if [[ ! -f "${MINIO_ENV}" ]]; then
  die "Fichier absent : ${MINIO_ENV}"
fi

set -a
# shellcheck disable=SC1090
source "${MINIO_ENV}"
set +a
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER manquant}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD manquant}"
: "${MINIO_BUCKET:=wise-eat}"

KUBECTL=(kubectl)
if command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(k3s kubectl)
fi

# 1. Vérifier que les 3 Deployments MinIO sont Ready.
for dep in minio minio-replica-1 minio-replica-2; do
  "${KUBECTL[@]}" -n "${NAMESPACE}" rollout status "deploy/${dep}" --timeout=120s
done

log "Purge SR (endpoints Docker) + re-add via Services k8s (${NAMESPACE})"

# 2. Job éphémère in-cluster — DNS *.svc.cluster.local résolu depuis le pod.
#    --force : écrase un pod mc-fix précédent éventuel.
"${KUBECTL[@]}" -n "${NAMESPACE}" delete pod mc-sr-repair --ignore-not-found --wait=true >/dev/null 2>&1 || true

"${KUBECTL[@]}" -n "${NAMESPACE}" run mc-sr-repair --restart=Never \
  --image="${MC_IMAGE}" \
  --env="MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
  --env="MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
  --env="MINIO_BUCKET=${MINIO_BUCKET}" \
  --env="MINIO_PUBLIC_READ=${MINIO_PUBLIC_READ:-true}" \
  --command -- /bin/sh -c '
    set -e
    mc alias set primary  http://minio.wise-eat.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
    mc alias set replica1 http://minio-replica-1.wise-eat.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
    mc alias set replica2 http://minio-replica-2.wise-eat.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

    # Purger toute SR résiduelle (même endpoints Docker morts).
    # Après rm sur primary, les peers peuvent déjà répondre « not enabled » — ignorer.
    mc admin replicate rm primary  --all --force || true
    mc admin replicate rm replica1 --all --force || true
    mc admin replicate rm replica2 --all --force || true

    # MinIO : un seul site peut avoir des données au moment du add.
    # Vider TOUS les buckets des réplicas (pas seulement MINIO_BUCKET).
    strip_all_buckets() {
      site="$1"
      mc ls "${site}" 2>/dev/null | while IFS= read -r line; do
        last=""
        for word in ${line}; do
          last="${word}"
        done
        b="${last%/}"
        [ -n "${b}" ] || continue
        echo "Suppression ${site}/${b}"
        mc rb --force "${site}/${b}" 2>/dev/null || true
      done
      # Filet si le parse mc ls rate (noms connus post-cutover).
      for b in "${MINIO_BUCKET}" wise-eat-writelock-test wise-eat-tmp wise-eat-repair; do
        mc rb --force "${site}/${b}" 2>/dev/null || true
      done
    }
    strip_all_buckets replica1
    strip_all_buckets replica2

    mc admin replicate add primary replica1 replica2

    # Syntaxe mc : resync start SOURCE CIBLE (un peer à la fois).
    mc admin replicate resync start primary replica1 || true
    mc admin replicate resync start primary replica2 || true

    if [ "${MINIO_PUBLIC_READ}" = "true" ]; then
      mc anonymous set download "primary/${MINIO_BUCKET}" || true
    fi

    mc admin replicate info primary
  '

# 3. Attendre la fin du pod + afficher les logs.
log "Attente job mc-sr-repair…"
for _ in $(seq 1 90); do
  phase="$("${KUBECTL[@]}" -n "${NAMESPACE}" get pod mc-sr-repair -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
  case "${phase}" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done

"${KUBECTL[@]}" -n "${NAMESPACE}" logs mc-sr-repair || true
phase="$("${KUBECTL[@]}" -n "${NAMESPACE}" get pod mc-sr-repair -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
"${KUBECTL[@]}" -n "${NAMESPACE}" delete pod mc-sr-repair --ignore-not-found --wait=false >/dev/null 2>&1 || true

if [[ "${phase}" != "Succeeded" ]]; then
  die "repair site-replication k8s échoué (phase=${phase}) — voir logs ci-dessus"
fi

# 4. Smoke PutObject sur le primaire (hostPort).
docker run --rm --network host \
  -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD -e MINIO_BUCKET \
  --entrypoint /bin/sh "${MC_IMAGE}" -c '
    set -e
    mc alias set p http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
    echo sr-ok | mc pipe "p/${MINIO_BUCKET}/system/storage-probe/sr-repair-$(date +%s).txt"
    echo WRITE_OK
  '

log "Site replication k8s OK (Services cluster.local) + smoke WRITE_OK"
