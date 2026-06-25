#!/usr/bin/env bash
# Site replication MinIO via mc (sh pur — image mc sans grep/awk/sed).
set -euo pipefail

configure_minio_site_replication_mc() {
  : "${MINIO_ROOT_USER:?MINIO_ROOT_USER requis}"
  : "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD requis}"
  : "${MINIO_BUCKET:=wise-eat}"

  local mc_image="${MINIO_MC_IMAGE:-minio/mc:RELEASE.2024-10-08T09-37-26Z}"

  log "Configuration site replication (mc admin replicate)"
  docker run --rm --network wise-eat-minio \
    --entrypoint /bin/sh \
    -e MINIO_ROOT_USER \
    -e MINIO_ROOT_PASSWORD \
    -e MINIO_BUCKET \
    -e MINIO_PUBLIC_READ="${MINIO_PUBLIC_READ:-true}" \
    "${mc_image}" \
    -c '
      set -e

      mc alias set primary http://wise-eat-minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
      mc alias set replica1 http://wise-eat-minio-replica-1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
      mc alias set replica2 http://wise-eat-minio-replica-2:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

      REPLICA1_MARKER="wise-eat-minio-replica-1"
      REPLICA2_MARKER="wise-eat-minio-replica-2"

      replication_info() {
        mc admin replicate info primary 2>&1 || true
      }

      site_in_pool() {
        marker="$1"
        info="$(replication_info)"
        case "${info}" in
          *"${marker}"*) return 0 ;;
          *) return 1 ;;
        esac
      }

      replication_not_enabled() {
        info="$(replication_info)"
        case "${info}" in
          *"not enabled"*|*"Not enabled"*|*"not configured"*|*"Not configured"*)
            return 0
            ;;
          *"SiteReplication enabled"*|*"Deployment ID"*)
            return 1
            ;;
          *)
            return 0
            ;;
        esac
      }

      mc mb --ignore-existing "primary/${MINIO_BUCKET}"

      strip_replica_buckets() {
        site="$1"
        mc rb --force "${site}/${MINIO_BUCKET}" 2>/dev/null || true
        mc ls "${site}" 2>/dev/null | while IFS= read -r line; do
          last=""
          for word in ${line}; do
            last="${word}"
          done
          b="${last%/}"
          [ -n "${b}" ] || continue
          echo "Suppression bucket ${site}/${b} (réplica doit être vide avant replication)"
          mc rb --force "${site}/${b}" 2>/dev/null || true
        done
      }

      apply_replicate_update() {
        mc admin replicate update primary \
          --replicate "existing-objects,delete,delete-marker,metadata-sync" \
          || mc admin replicate update primary --replicate "existing-objects" \
          || true
      }

      if site_in_pool "${REPLICA2_MARKER}"; then
        echo "Site replication complète (3 sites)"
        replication_info
      elif site_in_pool "${REPLICA1_MARKER}"; then
        echo "Ajout réplica 2 — pool existant primary + replica1"
        echo "MinIO exige de lister tous les sites du pool lors de l ajout"
        strip_replica_buckets replica2
        mc admin replicate add primary replica1 replica2
        apply_replicate_update
        echo "Site replication activée (3 sites)"
        replication_info
      elif replication_not_enabled; then
        echo "Activation site replication — primaire avec données, réplicas vides"
        strip_replica_buckets replica1
        strip_replica_buckets replica2
        mc admin replicate add primary replica1 replica2
        apply_replicate_update
        if replication_not_enabled; then
          echo "ERREUR: SiteReplication inactive après mc admin replicate add"
          replication_info
          exit 1
        fi
        echo "Site replication activée (3 sites)"
        replication_info
      else
        echo "État replication inattendu"
        replication_info
        exit 1
      fi

      if ! site_in_pool "${REPLICA2_MARKER}"; then
        echo "ERREUR: réplica 2 absent du pool après configuration"
        replication_info
        exit 1
      fi

      if [ "${MINIO_PUBLIC_READ}" = "true" ]; then
        mc anonymous set download "primary/${MINIO_BUCKET}" || true
      fi
    '
}
