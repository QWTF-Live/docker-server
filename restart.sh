#!/bin/bash

source .env.production
docker-compose -f production.yml down
docker-compose -f production.yml up -d

