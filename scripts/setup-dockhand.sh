#!/usr/bin/env bash
set -euo pipefail

echo "Setting up Dockhand..."

if docker container inspect dockhand >/dev/null 2>&1; then
    echo "Dockhand already exists."
    exit 0
fi

docker volume create dockhand_data

docker run -d \
    --name dockhand \
    --restart unless-stopped \
    -p 127.0.0.1:3000:3000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v dockhand_data:/app/data \
    "${DOCKHAND_IMAGE:-fnsys/dockhand:v1.0.59}"

echo "Dockhand setup completed."