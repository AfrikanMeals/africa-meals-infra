#!/usr/bin/env bash
# Déploiement API VPS : image + manifests k8s + HPA (5–10 pods) + nginx.

cd /opt/wise-eat
git pull
cd /opt/wise-eat-api
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod