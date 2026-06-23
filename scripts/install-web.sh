#!/usr/bin/env bash
# Installe nginx ou apache (WEB_SERVER=nginx|apache, défaut nginx).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

WEB_SERVER="${WEB_SERVER:-nginx}"
case "${WEB_SERVER}" in
  nginx)  bash "${SCRIPT_DIR}/install-nginx.sh" ;;
  apache) bash "${SCRIPT_DIR}/install-apache.sh" ;;
  *) die "WEB_SERVER invalide : ${WEB_SERVER} (nginx|apache)" ;;
esac
