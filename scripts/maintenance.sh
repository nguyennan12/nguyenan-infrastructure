#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"

source "$BASE/.env"

exec 9>"$BASE/backup.lock"
flock -n 9 || {
  echo "Another backup, deployment or infrastructure update is running." >&2
  exit 1
}

echo "===== Maintenance started: $(date -Is) ====="

# Check repository integrity
restic -o rclone.timeout=5m check

# Apply retention policy
restic -o rclone.timeout=5m forget \
  --group-by host,paths,tags \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3

# Reclaim unused storage
restic -o rclone.timeout=5m prune \
  --max-repack-size 50M

# Storage statistics
restic -o rclone.timeout=5m stats

echo "===== Maintenance completed: $(date -Is) ====="

