#!/usr/bin/env bash
# Resync fichiers core Matomo depuis l'image Docker (fix vendor/composer après update).
# Exécuté dans le conteneur wise-eat-matomo.
set -euo pipefail

SRC="${MATOMO_SRC:-/usr/src/matomo}"
DST="${MATOMO_DST:-/var/www/html}"

if [[ ! -d "${SRC}/vendor" ]]; then
  echo "MISSING_SRC_VENDOR" >&2
  exit 1
fi

echo "Resync vendor ← ${SRC}/vendor"
rm -rf "${DST}/vendor"
cp -a "${SRC}/vendor" "${DST}/vendor"

for path in core libs node_modules index.php matomo.php piwik.php js; do
  if [[ -e "${SRC}/${path}" ]]; then
    echo "Resync ${path}"
    rm -rf "${DST}/${path}"
    cp -a "${SRC}/${path}" "${DST}/${path}"
  fi
done

# Plugins système (pas plugins utilisateur ajoutés manuellement)
if [[ -d "${SRC}/plugins" ]]; then
  echo "Resync plugins système"
  find "${SRC}/plugins" -mindepth 1 -maxdepth 1 -type d ! -name 'Marketplace' -print0 \
    | while IFS= read -r -d '' plugin; do
        name="$(basename "${plugin}")"
        rm -rf "${DST}/plugins/${name}"
        cp -a "${plugin}" "${DST}/plugins/${name}"
      done
fi

chown -R www-data:www-data "${DST}/vendor" "${DST}/core" "${DST}/libs" 2>/dev/null || \
  chown -R 33:33 "${DST}/vendor" "${DST}/core" "${DST}/libs" 2>/dev/null || true

echo "RESYNC_OK"
