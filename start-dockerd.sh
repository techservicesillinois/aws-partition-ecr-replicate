#!/bin/bash

set -e
set -o pipefail

dockerd &
docker_pid=$!
echo "Started dockerd with pid $docker_pid"

docker_wait=60
while (( docker_wait > 0 )); do
    sleep 1
    (( docker_wait-- )) || :

    if ! kill -0 $docker_pid &>/dev/null; then
        echo "docker daemon is not running"
        exit 1
    fi
    if docker system info &>/dev/null; then
        echo "docker daemon is running"
        break
    fi
done
if ! docker system info &>/dev/null; then
    echo "docker daemon failed to start"
    exit 1
fi
