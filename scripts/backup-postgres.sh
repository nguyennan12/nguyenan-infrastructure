#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"

source "$BASE/.env"

# Prevent concurrent backups
exec 9>"$BASE/backup.lock"
flock -n 9 || exit 1

echo "===== Backup started: $(date -Is) ====="

mkdir -p "$BASE/staging"

# Export PostgreSQL
docker exec infra-postgres pg_dumpall \
  -U infra_admin \
  > "$BASE/staging/postgres.sql"

test -s "$BASE/staging/postgres.sql"

# Upload encrypted backup
restic -o rclone.timeout=5m \
  --compression off \
  backup "$BASE/staging/postgres.sql" \
  --tag postgresql

# Remove local SQL after successful backup
rm -f "$BASE/staging/postgres.sql"

echo "===== Backup completed: $(date -Is) ====="
