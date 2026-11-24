#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo "This bootstrap requires Ubuntu 24.04."
    exit 1
fi

# Prevent accidental execution on existing infrastructure
if command -v docker >/dev/null 2>&1; then
    if [ -n "$(docker ps -aq)" ]; then
        echo "Existing Docker containers detected."
        echo "Bootstrap is intended for a fresh VPS."
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo " NguyenAn Infrastructure Bootstrap"
echo "======================================"

bash "$SCRIPT_DIR/setup-system.sh"
bash "$SCRIPT_DIR/setup-docker.sh"
bash "$SCRIPT_DIR/setup-network.sh"
bash "$SCRIPT_DIR/setup-directories.sh"
bash "$SCRIPT_DIR/setup-cockpit.sh"

echo "======================================"
echo " Base infrastructure setup completed"
echo "======================================"

docker --version
docker compose version
docker network ls
free -h
df -h

echo "Next: configure /opt/infra/infrastructure.env, restore secrets and install Dockhand."