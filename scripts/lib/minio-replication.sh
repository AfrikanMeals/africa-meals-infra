#!/usr/bin/env bash
# Site replication MinIO via mc (sans grep — image mc minimale).
set -euo pipefail

configure_minio_site_replication_mc() {
  : "${MINIO_ROOT_USER:?MINIO_ROOT_USER requis}"
  : "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD requis}"
  : "${MINIO_BUCKET:=wise-eat}"

  log "Configuration site replication (mc admin replicate)"
  docker run --rm --network wise-eat-minio \
    --entrypoint /bin/sh \
    -e MINIO_ROOT_USER \
    -e MINIO_ROOT_PASSWORD \
    -e MINIO_BUCKET \
    -e MINIO_PUBLIC_READ="${MINIO_PUBLIC_READ:-true}" \
    minio/mc:RELEASE.2024-10-08T09-37-26Z \
    -c '
      set -e
      mc alias set primary http://wise-eat-minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
      mc alias set replica1 http://wise-eat-minio-replica-1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
      mc alias set replica2 http://wise-eat-minio-replica-2:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

      # Seul le primaire peut avoir des données/buckets avant la 1re config site replication.
      mc mb --ignore-existing "primary/${MINIO_BUCKET}"

      strip_replica_buckets() {
        site="$1"
        buckets="$(mc ls "${site}" 2>/dev/null | awk "{print \$NF}" || true)"
        for b in ${buckets}; do
          [ -n "${b}" ] || continue
          echo "Suppression bucket ${site}/${b} (réplica doit être vide avant replication)"
          mc rb --force "${site}/${b}" || true
        done
      }
      strip_replica_buckets replica1
      strip_replica_buckets replica2

      if mc admin replicate info primary >/dev/null 2>&1; then
        echo "Site replication déjà active"
        mc admin replicate info primary
      else
        echo "Activation site replication — primaire avec données, réplicas vides"
        mc admin replicate add primary replica1
        mc admin replicate add primary replica2
        mc admin replicate update primary \
          --replicate "existing-objects,delete,delete-marker,metadata-sync" \
          || mc admin replicate update primary --replicate "existing-objects" \
          || true
        mc admin replicate info primary
      fi

      if [ "${MINIO_PUBLIC_READ}" = "true" ]; then
        mc anonymous set download "primary/${MINIO_BUCKET}" || true
      fi
    '
}
