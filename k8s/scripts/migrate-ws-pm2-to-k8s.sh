#!/usr/bin/env bash
# Déprécié — utiliser deploy-ws-production.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-ws-production.sh" "$@"
