#!/usr/bin/env bash

cd /opt/wise-eat
git pull
cd /opt/wise-eat-api
git pull
sudo /opt/wise-eat/k8s/scripts/deploy-api-production.sh /opt/wise-eat-api/.env.prod