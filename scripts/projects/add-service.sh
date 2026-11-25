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
if [ -f "$REGISTRY_CORE" ]; then
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then exec bash "$REGISTRY_CORE" add "$@"; fi
    if [ ! -s "$REGISTRY_DIR_CANDIDATE/stacks.json" ] || [ ! -s "$REGISTRY_DIR_CANDIDATE/services.json" ]; then
        echo "Installed service registry is missing; refusing legacy fallback." >&2
        exit 1
    fi
    exec bash "$REGISTRY_CORE" add "$@"
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
    echo "  --all"
    exit 1
fi

PROJECT="$1"
shift

validate_project "$PROJECT"
init_project_paths "$PROJECT"

install -d -m 700 /opt/infra/state

exec 9>/opt/infra/state/provisioning.lock

flock -n 9 || {
    echo "Another provisioning task is running."
    exit 1
}

if [ ! -f "$MANIFEST" ]; then
    echo "Project manifest not found."
    echo "Legacy projects require migration first."
    exit 1
fi

test -f "$ENV_FILE"

if [ "$(jq -r '.status' "$MANIFEST")" != "provisioned" ]; then
    echo "Project is not in a provisioned state."
    exit 1
fi

USE_POSTGRES=false
USE_REDIS=false
USE_MINIO=false

for arg in "$@"; do
    case "$arg" in
        --postgres) USE_POSTGRES=true ;;
        --redis) USE_REDIS=true ;;
        --minio) USE_MINIO=true ;;
        --all)
            USE_POSTGRES=true
            USE_REDIS=true
            USE_MINIO=true
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# Skip existing services
if has_service postgres; then
    USE_POSTGRES=false
fi

if has_service redis; then
    USE_REDIS=false
fi

if has_service minio; then
    USE_MINIO=false
fi

if ! $USE_POSTGRES &&
   ! $USE_REDIS &&
   ! $USE_MINIO; then

    echo "No new services to provision."
    exit 0
fi

load_infra_config

# Validate selected services
if $USE_POSTGRES; then
    require_container infra-postgres
fi

if $USE_REDIS; then
    require_container infra-redis
fi

if $USE_MINIO; then
    require_container infra-minio
    command -v mc >/dev/null
fi

echo "========== ADD SERVICES =========="
echo "Project:    $PROJECT"
echo "PostgreSQL: $USE_POSTGRES"
echo "Redis:      $USE_REDIS"
echo "MinIO:      $USE_MINIO"
echo "=================================="

read -r -p "Type ADD $PROJECT to continue: " CONFIRM

if [ "$CONFIRM" != "ADD $PROJECT" ]; then
    echo "Operation cancelled."
    exit 1
fi

set_project_status provisioning

trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    set_project_status incomplete || true
    echo "Provisioning failed. Review partial resources."
fi' EXIT

if $USE_POSTGRES; then
    create_postgres
fi

if $USE_REDIS; then
    create_redis
fi

if $USE_MINIO; then
    create_minio
fi

set_project_status provisioned

trap - EXIT

echo "Services added successfully."
jq '.services' "$MANIFEST"

echo "Credentials: $ENV_FILE"
