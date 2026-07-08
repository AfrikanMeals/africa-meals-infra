#!/bin/bash

set -euxo pipefail

cd /opt/wise-eat
git pull
cd /opt/wise-eat-api
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod "$@"


cd /opt/wise-eat
git pull
cd /opt/wise-eat-ws
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-ws-production.sh /opt/wise-eat-ws/.env.prod "$@"

DEPLOY_CLEANUP_KEEP_BUILD_CACHE_GB=5 sudo /opt/wise-eat/k8s/scripts/lib/post-deploy-disk-cleanup.sh all
