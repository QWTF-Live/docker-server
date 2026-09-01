#!/bin/bash

cd "$(dirname "$0")" || exit 1

docker compose -f production.yml exec updater /updater/sync.sh
