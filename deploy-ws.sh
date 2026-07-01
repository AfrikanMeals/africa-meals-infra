#!/usr/bin/env bash

cd /opt/wise-eat
git pull
cd /opt/wise-eat-ws
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-ws-production.sh /opt/wise-eat-ws/.env.prod