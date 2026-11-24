#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/postgres.sh"
source "$SCRIPT_DIR/lib/redis.sh"
source "$SCRIPT_DIR/lib/minio.sh"

require_root

if [ "$#" -lt 1 ]; then
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

USE_POSTGRES=false
USE_REDIS=false
USE_MINIO=false

if [ "$#" -eq 0 ]; then

    echo "======================================"
    echo " Infrastructure Project Provisioning"
    echo "======================================"
    echo "Project: $PROJECT"
    echo
    echo "1. PostgreSQL"
    echo "2. Redis"
    echo "3. MinIO"
    echo "4. All services"
    echo

    read -r -p "Select services (example: 1 2): " -a choices

    for choice in "${choices[@]}"; do
        case "$choice" in
            1) USE_POSTGRES=true ;;
            2) USE_REDIS=true ;;
            3) USE_MINIO=true ;;
            4)
                USE_POSTGRES=true
                USE_REDIS=true
                USE_MINIO=true
                ;;
            *)
                echo "Invalid selection: $choice"
                exit 1
                ;;
        esac
    done

else

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
fi

if ! $USE_POSTGRES &&
   ! $USE_REDIS &&
   ! $USE_MINIO; then

    echo "Select at least one service."
    exit 1
fi

command -v jq >/dev/null
command -v openssl >/dev/null

load_infra_config

install -d -m 700 "$PROJECTS_DIR"
install -d -m 700 /opt/infra/state

exec 9>/opt/infra/state/provisioning.lock

flock -n 9 || {
    echo "Another provisioning task is running."
    exit 1
}

if [ -e "$PROJECT_DIR" ]; then
    echo "Project already exists."
    exit 1
fi

# Check selected services only
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

echo
echo "========== PROVISIONING PLAN =========="
echo "Project:    $PROJECT"
echo "PostgreSQL: $USE_POSTGRES"
echo "Redis:      $USE_REDIS"
echo "MinIO:      $USE_MINIO"
echo "======================================"

read -r -p "Type CREATE $PROJECT to continue: " CONFIRM

if [ "$CONFIRM" != "CREATE $PROJECT" ]; then
    echo "Provisioning cancelled."
    exit 1
fi

mkdir -m 700 "$PROJECT_DIR"

printf 'PROJECT_NAME=%s\n' "$PROJECT" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

init_manifest

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

echo
echo "======================================"
echo "Project created successfully: $PROJECT"
echo "======================================"

jq '.services' "$MANIFEST"

echo "Credentials: $ENV_FILE"
echo "Manifest: $MANIFEST"