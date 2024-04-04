#!/bin/bash
function work() {
  docker pull qwtflive/updater
  source .env.production
  docker-compose -f production.yml down
  docker-compose -f production.yml up -d
}
WORK=$(declare -f work)

git pull --ff-only

sudo bash -c "$WORK; work;"

