#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"

source "$BASE/.env"

# Direct component runs acquire the shared lock. backup-all.sh already holds it.
if [ "${BACKUP_LOCK_HELD:-0}" != "1" ]; then
  exec 9>"$BASE/backup.lock"
  flock -n 9 || { echo "Another backup, deployment or infrastructure update is running." >&2; exit 1; }
fi

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
