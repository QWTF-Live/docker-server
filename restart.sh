#!/bin/bash
function work() {
  source ../tfl_host.env
  source ../qwtflive.env.production
  docker compose -f production.yml pull
  docker image prune -f
  docker compose -f production.yml down --remove-orphans
  docker compose -f production.yml up -d
}
WORK=$(declare -f work)

git pull --ff-only

sudo bash -c "cd $(dirname "$(readlink -f "$0")"); $WORK; work;"
