#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"
STAGING="$BASE/staging/minio"
CONTAINER="infra-minio"
TEMP="/tmp/minio-infra-backup"

source "$BASE/.env"

# Direct component runs acquire the shared lock. backup-all.sh already holds it.
if [ "${BACKUP_LOCK_HELD:-0}" != "1" ]; then
  exec 9>"$BASE/backup.lock"
  flock -n 9 || { echo "Another backup, deployment or infrastructure update is running." >&2; exit 1; }
fi

echo "===== MinIO backup started: $(date -Is) ====="

# Prepare directories
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Cleanup temporary container data
trap 'docker exec "$CONTAINER" rm -rf "$TEMP" >/dev/null 2>&1 || true' EXIT

docker exec "$CONTAINER" sh -ec '
  umask 077

  TEMP="/tmp/minio-infra-backup"

  rm -rf "$TEMP"
  mkdir -p "$TEMP/objects"

  mc alias set backup-local \
    http://127.0.0.1:9000 \
    "$MINIO_ROOT_USER" \
    "$MINIO_ROOT_PASSWORD" >/dev/null

  cd "$TEMP"

  # Export IAM
  mc admin cluster iam export backup-local \
    --output "$TEMP/iam-metadata.zip"

  # Export bucket metadata
  mc admin cluster bucket export backup-local

  # Export server configuration
  mc admin config export backup-local \
    > "$TEMP/config.txt"

  # Backup objects
  mc mirror --overwrite \
    backup-local/ "$TEMP/objects/"
'

# Copy backup to host
docker cp "$CONTAINER:$TEMP/." "$STAGING/"

chmod -R go-rwx "$STAGING"

# Upload encrypted backup
restic -o rclone.timeout=5m \
  --compression off \
  backup "$STAGING" \
  --tag minio

# Cleanup after successful upload
rm -rf "$STAGING"

echo "===== MinIO backup completed: $(date -Is) ====="
