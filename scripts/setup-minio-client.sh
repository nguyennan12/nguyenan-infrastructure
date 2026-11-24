#!/usr/bin/env bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

if command -v mc >/dev/null 2>&1 &&
   mc --version 2>&1 | grep -q RELEASE; then

    echo "MinIO Client already installed."
    mc --version
    exit 0
fi

if ! docker container inspect infra-minio >/dev/null 2>&1; then
    echo "MinIO container not found."
    echo "Deploy MinIO before running this script."
    exit 1
fi

MC_PATH="$(docker exec infra-minio \
    sh -c 'command -v mc')"

if [ -z "$MC_PATH" ]; then
    echo "MinIO Client not found inside container."
    exit 1
fi

docker cp \
    "infra-minio:$MC_PATH" \
    /usr/local/bin/mc

chmod 755 /usr/local/bin/mc

/usr/local/bin/mc --version

echo "MinIO Client installed successfully."