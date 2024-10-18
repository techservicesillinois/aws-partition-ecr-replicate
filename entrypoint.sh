#!/bin/bash

cd /app
start-dockerd.sh
exec python3.11 partition_ecr_replicate.py "$@"
