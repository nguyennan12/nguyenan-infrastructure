#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    REGISTRY_CORE="$SCRIPT_DIR/orchestrator.sh"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
    REGISTRY_CORE="$SCRIPT_DIR/project-services.sh"
fi
REGISTRY_DIR_CANDIDATE="$(cd "$SCRIPTS_ROOT/.." && pwd)/registry"
if [ -f "$REGISTRY_CORE" ] && [ -s "$REGISTRY_DIR_CANDIDATE/stacks.json" ] &&
   [ -s "$REGISTRY_DIR_CANDIDATE/services.json" ]; then
    exec bash "$REGISTRY_CORE" delete "$@"
fi

if [ -f "$SCRIPTS_ROOT/core/common.sh" ]; then
    source "$SCRIPTS_ROOT/core/common.sh"
    source "$SCRIPTS_ROOT/services/postgres/provision.sh"
    source "$SCRIPTS_ROOT/services/redis/provision.sh"
    source "$SCRIPTS_ROOT/services/minio/provision.sh"
else
    source "$SCRIPT_DIR/lib/common.sh"
    source "$SCRIPT_DIR/lib/postgres.sh"
    source "$SCRIPT_DIR/lib/redis.sh"
    source "$SCRIPT_DIR/lib/minio.sh"
fi

require_root

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <project-name>"
    exit 1
fi

PROJECT="$1"

validate_project "$PROJECT"
init_project_paths "$PROJECT"
acquire_destructive_project_locks
require_managed_project

echo "========== DELETE PROJECT =========="
echo "Project: $PROJECT"

jq '.services' "$MANIFEST"

echo "===================================="

if has_service postgres; then
    require_container infra-postgres
fi

if has_service redis; then
    require_container infra-redis
fi

if has_service minio; then
    require_container infra-minio
    command -v mc >/dev/null
fi

echo "WARNING: All registered project resources will be deleted."
echo "Stop the project application before continuing."

read -r -p "Type DELETE $PROJECT to continue: " CONFIRM

if [ "$CONFIRM" != "DELETE $PROJECT" ]; then
    echo "Deletion cancelled."
    exit 1
fi

echo "Creating backup before deletion..."

/opt/infra/backup/backup-all.sh

set_project_status deleting

trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    set_project_status incomplete || true
    echo "Deletion failed. Review remaining resources."
fi' EXIT

if has_service postgres; then
    remove_postgres
fi

if has_service redis; then
    remove_redis
fi

if has_service minio; then
    remove_minio
fi

# Ensure all services have been removed
jq -e '
    .services | all(.[]; . == false)
' "$MANIFEST" >/dev/null

rm -rf -- "$PROJECT_DIR"

trap - EXIT

echo "===================================="
echo "Project deleted successfully: $PROJECT"
echo "===================================="
