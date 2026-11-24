#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

BACKUP_DIR="/opt/infra/backup"
RESTORE_DIR="/opt/infra/restore"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

acquire_restore_locks

if [ -n "$(docker ps -q)" ]; then
    echo "Running containers detected."
    echo "Restore requires an isolated recovery environment."
    exit 1
fi

umask 077

set -a
source "$BACKUP_DIR/.env"
set +a

mkdir -p "$RESTORE_DIR"

echo "Checking backup repository..."
restic -o rclone.timeout=5m check

echo "Available snapshots:"
restic -o rclone.timeout=5m snapshots

for service in postgresql redis minio infrastructure; do
    echo "Restoring $service..."

    TARGET=$(mktemp -d "$RESTORE_DIR/$service.XXXXXX")

    restic -o rclone.timeout=5m restore latest \
        --host "$SOURCE_HOST" \
        --tag "$service" \
        --target "$TARGET"

    echo "Restored to $TARGET"
done

echo "Backup extraction completed."
echo "Verify files before importing service data."
