#!/bin/bash

set -uo pipefail

BASE="${BACKUP_DIR:-/opt/infra/backup}"
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
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

if [ -s "$INFRA_ROOT/registry/stacks.json" ] &&
   [ -s "$INFRA_ROOT/registry/services.json" ] &&
   [ -s "$INFRA_ROOT/scripts/core/registry.sh" ]; then
    REGISTRY_ROOT="$INFRA_ROOT/registry"
    REGISTRY_TRUSTED_ROOT="$INFRA_ROOT"
    export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT INFRA_ROOT
    source "$INFRA_ROOT/scripts/core/registry.sh"
    registry_validate || exit 1

    while IFS= read -r service; do
        backup_source="$(registry_service_get "$service" | jq -r '.backup.script')"
        backup_destination="$(registry_service_get "$service" | jq -r --arg source "$backup_source" \
            '.managed_files[] | select(.source == $source) | .destination')"
        case "$backup_destination" in
            backup/backup-*.sh) backup_script="$(basename "$backup_destination")" ;;
            *) echo "[FAILED] invalid backup runtime mapping for $service" >&2; FAILED=1; continue ;;
        esac
        required="$(registry_service_get "$service" | jq -r '.backup.required_when_enabled')"

        if ! registry_run_service_hook "$service" backup_available >/dev/null 2>&1; then
            if [ "$required" = "true" ]; then
                echo "[FAILED] enabled backup service is unavailable: $service" >&2
                FAILED=1
            else
                echo "[SKIPPED] optional enabled backup service is unavailable: $service"
            fi
            continue
        fi

        if "$BASE/$backup_script"; then
            echo "[SUCCESS] $service"
        else
            echo "[FAILED] $service"
            FAILED=1
        fi
    done < <(registry_backup_services)
else
    echo "Registry is not installed; using the production-compatible legacy backup order."
    for service in postgres redis minio; do
        if "$BASE/backup-$service.sh"; then
            echo "[SUCCESS] $service"
        else
            echo "[FAILED] $service"
            FAILED=1
        fi
    done
fi

if "$BASE/backup-infra.sh"; then
    echo "[SUCCESS] infra"
else
    echo "[FAILED] infra"
    FAILED=1
fi

echo "===== FULL BACKUP FINISHED: $(date -Is) ====="

exit "$FAILED"
