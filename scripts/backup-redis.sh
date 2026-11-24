#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"

source "$BASE/.env"

# Prevent concurrent backups
exec 9>"$BASE/backup.lock"
flock -n 9 || exit 1

echo "===== Redis backup started: $(date -Is) ====="

mkdir -p "$BASE/staging"

# Remove temporary container file on exit
trap 'docker exec infra-redis rm -f /tmp/backup.rdb >/dev/null 2>&1 || true' EXIT

# Create consistent RDB snapshot
docker exec -i infra-redis sh -c '
    IFS= read -r REDISCLI_AUTH
    export REDISCLI_AUTH
    redis-cli --rdb /tmp/backup.rdb &&
    redis-check-rdb /tmp/backup.rdb
' < "$BASE/.redis-password"

# Copy snapshot to staging
docker cp \
    infra-redis:/tmp/backup.rdb \
    "$BASE/staging/redis.rdb"

chmod 600 "$BASE/staging/redis.rdb"

test -s "$BASE/staging/redis.rdb"

# Backup persistent ACL
docker cp \
    infra-redis:/data/users.acl \
    "$BASE/staging/users.acl"

chmod 600 "$BASE/staging/users.acl"

test -s "$BASE/staging/users.acl"

# Upload encrypted backup
restic -o rclone.timeout=5m \
    --compression off \
    backup "$BASE/staging/redis.rdb" \
           "$BASE/staging/users.acl" \
    --tag redis

# Clean up local snapshots
rm -f \
    "$BASE/staging/redis.rdb" \
    "$BASE/staging/users.acl"

echo "===== Redis backup completed: $(date -Is) ====="