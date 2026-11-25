#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
source "$SCRIPTS_ROOT/core/common.sh"

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

restore_snapshot_files() {
    local name="$1"
    local tag="$2"
    local target

    echo "Restoring $name files from tag $tag..."

    target=$(mktemp -d "$RESTORE_DIR/$name.XXXXXX")

    restic -o rclone.timeout=5m restore latest \
        --host "$SOURCE_HOST" \
        --tag "$tag" \
        --target "$target"

    echo "Restored to $target"
}

# Infrastructure configuration and credentials are always the first extraction phase.
restore_snapshot_files infrastructure infrastructure

if [ -s "$INFRA_ROOT/registry/stacks.json" ] &&
   [ -s "$INFRA_ROOT/registry/services.json" ] &&
   [ -s "$INFRA_ROOT/scripts/core/registry.sh" ]; then
    REGISTRY_ROOT="$INFRA_ROOT/registry"
    REGISTRY_TRUSTED_ROOT="$INFRA_ROOT"
    export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT
    source "$INFRA_ROOT/scripts/core/registry.sh"
    registry_validate
    while IFS=$'\t' read -r service phase _script tag; do
        echo "Restore phase: $phase ($service)"
        restore_snapshot_files "$service" "$tag"
    done < <(registry_restore_plan)
else
    echo "Registry is unavailable; using the older snapshot-compatible restore extraction plan."
    restore_snapshot_files redis redis
    restore_snapshot_files postgres postgresql
    restore_snapshot_files minio minio
fi

echo "Backup extraction completed."
echo "Verify files before importing service data."
