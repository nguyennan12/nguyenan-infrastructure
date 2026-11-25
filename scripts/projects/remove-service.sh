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
    exec bash "$REGISTRY_CORE" remove "$@"
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

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <project-name> [services]"
    echo "Options:"
    echo "  --postgres"
    echo "  --redis"
    echo "  --minio"
    exit 1
fi

PROJECT="$1"
shift

validate_project "$PROJECT"
init_project_paths "$PROJECT"
acquire_destructive_project_locks
require_managed_project

REMOVE_POSTGRES=false
REMOVE_REDIS=false
REMOVE_MINIO=false

for arg in "$@"; do
    case "$arg" in
        --postgres) REMOVE_POSTGRES=true ;;
        --redis) REMOVE_REDIS=true ;;
        --minio) REMOVE_MINIO=true ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

if ! has_service postgres; then
    REMOVE_POSTGRES=false
fi

if ! has_service redis; then
    REMOVE_REDIS=false
fi

if ! has_service minio; then
    REMOVE_MINIO=false
fi

if ! $REMOVE_POSTGRES &&
   ! $REMOVE_REDIS &&
   ! $REMOVE_MINIO; then

    echo "No matching services to remove."
    exit 0
fi

if $REMOVE_POSTGRES; then
    require_container infra-postgres
fi

if $REMOVE_REDIS; then
    require_container infra-redis
fi

if $REMOVE_MINIO; then
    require_container infra-minio
    command -v mc >/dev/null
fi

echo "========== REMOVE SERVICES =========="
echo "Project:    $PROJECT"
echo "PostgreSQL: $REMOVE_POSTGRES"
echo "Redis:      $REMOVE_REDIS"
echo "MinIO:      $REMOVE_MINIO"
echo "====================================="

echo "WARNING: Selected service data will be deleted."
echo "Stop the project application before continuing."

read -r -p "Type REMOVE $PROJECT to continue: " CONFIRM

if [ "$CONFIRM" != "REMOVE $PROJECT" ]; then
    echo "Operation cancelled."
    exit 1
fi

echo "Creating backup before removal..."

/opt/infra/backup/backup-all.sh

set_project_status removing

trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    set_project_status incomplete || true
    echo "Removal failed. Review partial resources."
fi' EXIT

if $REMOVE_POSTGRES; then
    remove_postgres
fi

if $REMOVE_REDIS; then
    remove_redis
fi

if $REMOVE_MINIO; then
    remove_minio
fi

set_project_status provisioned

trap - EXIT

echo "Services removed successfully."

jq '.services' "$MANIFEST"
