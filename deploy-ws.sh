#!/usr/bin/env bash
# Déploiement WS VPS : image + manifests k8s + HPA (3–5 pods) + nginx.

cd /opt/wise-eat
git pull
cd /opt/wise-eat-ws
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-ws-production.sh /opt/wise-eat-ws/.env.prod