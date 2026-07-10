#!/usr/bin/env bash
# Déploiement API VPS : image + manifests k8s + HPA (5–10 pods) + nginx + nettoyage disque.

set -euo pipefail

cd /opt/wise-eat
git pull
cd /opt/wise-eat-api
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod "$@"

DEPLOY_CLEANUP_KEEP_BUILD_CACHE_GB=5 sudo /opt/wise-eat/k8s/scripts/lib/post-deploy-disk-cleanup.sh all
