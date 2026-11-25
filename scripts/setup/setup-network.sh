#!/usr/bin/env bash
set -euo pipefail

echo "[3/4] Setting up Docker networks..."

if ! docker network inspect proxy >/dev/null 2>&1; then
    docker network create proxy
else
    echo "Network proxy already exists."
fi

echo "Network setup completed."