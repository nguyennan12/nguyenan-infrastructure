#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/infra/backup"

install -d -m 700 "$BACKUP_DIR"

for file in .env .restic-password rclone.conf; do
    if [ ! -s "$BACKUP_DIR/$file" ]; then
        echo "Missing backup configuration: $file"
        exit 1
    fi

    chmod 600 "$BACKUP_DIR/$file"
done

set -a
source "$BACKUP_DIR/.env"
set +a

echo "Checking backup repository..."

restic -o rclone.timeout=5m snapshots

echo "Backup configuration verified."