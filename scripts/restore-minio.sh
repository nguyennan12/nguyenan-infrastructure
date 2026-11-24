#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

acquire_restore_locks

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/minio-backup"
    exit 1
fi

BACKUP_DIR="$(realpath "$1")"
ALIAS="recovery-local"

test -s "$BACKUP_DIR/backup-local-bucket-metadata.zip"
test -s "$BACKUP_DIR/iam-metadata.zip"
test -d "$BACKUP_DIR/objects"

command -v mc >/dev/null

: "${MINIO_ROOT_USER:?Missing MINIO_ROOT_USER}"
: "${MINIO_ROOT_PASSWORD:?Missing MINIO_ROOT_PASSWORD}"

umask 077
MC_CONFIG_DIR="$(mktemp -d)"
export MC_CONFIG_DIR

trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

mc alias set "$ALIAS" \
    http://127.0.0.1:9000 \
    "$MINIO_ROOT_USER" \
    "$MINIO_ROOT_PASSWORD"

mc admin info "$ALIAS"

if [ -n "$(mc ls "$ALIAS")" ]; then
    echo "Existing buckets detected. Restore aborted."
    exit 1
fi

read -r -p "Type RESTORE on a fresh recovery VPS: " CONFIRM
[ "$CONFIRM" = "RESTORE" ] || exit 1

echo "Restoring bucket metadata..."

mc admin cluster bucket import \
    "$ALIAS" \
    "$BACKUP_DIR/backup-local-bucket-metadata.zip"

echo "Restoring objects..."

for bucket_dir in "$BACKUP_DIR"/objects/*; do
    [ -d "$bucket_dir" ] || continue

    bucket="$(basename "$bucket_dir")"

    mc mb --ignore-existing "$ALIAS/$bucket"

    mc mirror \
        "$bucket_dir" \
        "$ALIAS/$bucket"
done

echo "Restoring IAM metadata..."

mc admin cluster iam import \
    "$ALIAS" \
    "$BACKUP_DIR/iam-metadata.zip"

echo "MinIO restore completed."

mc ls "$ALIAS"
mc admin user list "$ALIAS"
mc admin policy list "$ALIAS"
