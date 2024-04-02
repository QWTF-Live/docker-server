#!/bin/bash
git pull --ff-only
source .env.production
docker-compose -f production.yml down
docker-compose -f production.yml up -d

