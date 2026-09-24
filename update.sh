#!/bin/bash

cd "$(dirname "$0")" || exit 1

docker compose -f production.yml exec fortressone /updater/sync.sh
