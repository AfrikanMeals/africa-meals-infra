#!/bin/bash

set -euxo pipefail
cd /opt/wise-eat
git pull
cd /opt/wise-eat-api
git pull
cd /opt/wise-eat-ws
git pull
