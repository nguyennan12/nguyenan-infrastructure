#!/bin/bash

set -uo pipefail

BASE="${BACKUP_DIR:-/opt/infra/backup}"
FAILED=0

if [ "${BACKUP_LOCK_HELD:-0}" != "1" ]; then
    exec 9>"$BASE/backup.lock"
    flock -n 9 || {
        echo "Another backup, deployment or infrastructure update is running." >&2
        exit 1
    }
fi

export BACKUP_LOCK_HELD=1

echo "===== FULL BACKUP STARTED: $(date -Is) ====="

for service in postgres redis minio infra; do
    if "$BASE/backup-$service.sh"; then
        echo "[SUCCESS] $service"
    else
        echo "[FAILED] $service"
        FAILED=1
    fi
done

echo "===== FULL BACKUP FINISHED: $(date -Is) ====="

exit "$FAILED"
