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

      replication_enabled() {
        info="$(mc admin replicate info primary 2>&1)" || info="${info}"
        case "${info}" in
          *"not enabled"*|*"Not enabled"*|*"not configured"*|*"Not configured"*)
            return 1
            ;;
          *"ERROR"*|*"Unable"*)
            return 1
            ;;
        esac
        printf "%s\n" "${info}"
        return 0
      }

      # Seul le primaire peut avoir des données/buckets avant la 1re config site replication.
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
      strip_replica_buckets replica1
      strip_replica_buckets replica2

      if replication_enabled; then
        echo "Site replication déjà active"
      else
        echo "Activation site replication — primaire avec données, réplicas vides"
        set +e
        mc admin replicate add primary replica1
        add1=$?
        mc admin replicate add primary replica2
        add2=$?
        set -e
        if [ "${add1}" -ne 0 ] || [ "${add2}" -ne 0 ]; then
          echo "mc admin replicate add a échoué (codes ${add1}, ${add2})"
          mc admin replicate info primary 2>&1 || true
          exit 1
        fi
        mc admin replicate update primary \
          --replicate "existing-objects,delete,delete-marker,metadata-sync" \
          || mc admin replicate update primary --replicate "existing-objects" \
          || true
        if ! replication_enabled; then
          echo "ERREUR: SiteReplication toujours inactive après mc admin replicate add"
          mc admin replicate info primary 2>&1 || true
          exit 1
        fi
        echo "Site replication activée"
      fi

      if [ "${MINIO_PUBLIC_READ}" = "true" ]; then
        mc anonymous set download "primary/${MINIO_BUCKET}" || true
      fi
    '
}
