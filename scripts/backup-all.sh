#!/bin/bash

set -uo pipefail

BASE="/opt/infra/backup"
FAILED=0

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
