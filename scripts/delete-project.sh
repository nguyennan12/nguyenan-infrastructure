#!/usr/bin/env bash

set -euo pipefail
umask 077

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <project-name>"
    exit 1
fi

PROJECT="$1"

if [[ ! "$PROJECT" =~ ^[a-z][a-z0-9]{2,29}$ ]]; then
    echo "Invalid project name."
    exit 1
fi

PROJECT_DIR="/opt/infra/projects/$PROJECT"

DB_NAME="${PROJECT}_db"
DB_USER="${PROJECT}_user"

REDIS_USER="${PROJECT}_user"

MINIO_BUCKET="$PROJECT"
MINIO_USER="${PROJECT}_user"
MINIO_POLICY="${PROJECT}-policy"

if [ ! -f "$PROJECT_DIR/.provisioned" ]; then
    echo "Managed project not found."
    exit 1
fi

for container in infra-postgres infra-redis infra-minio; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
        echo "Container $container is not running."
        exit 1
    fi
done

command -v mc >/dev/null

REDIS_ADMIN_PASSWORD="$(cat /opt/infra/backup/.redis-password)"

pg() {
    docker exec -i infra-postgres \
        psql -X -v ON_ERROR_STOP=1 \
        -U infra_admin -d postgres "$@"
}

redis() {
    docker exec -i \
        -e REDISCLI_AUTH="$REDIS_ADMIN_PASSWORD" \
        infra-redis redis-cli --raw "$@"
}

read -r -p "MinIO root username: " MINIO_ROOT_USER
read -r -s -p "MinIO root password: " MINIO_ROOT_PASSWORD
echo

MC_CONFIG_DIR="$(mktemp -d)"
export MC_CONFIG_DIR

trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

mc alias set deletion-local \
    http://127.0.0.1:9000 \
    "$MINIO_ROOT_USER" \
    "$MINIO_ROOT_PASSWORD" >/dev/null

mc admin info deletion-local >/dev/null

test "$(redis PING)" = "PONG"

echo
echo "========== DELETION PLAN =========="
echo "Project: $PROJECT"
echo "PostgreSQL database: $DB_NAME"
echo "PostgreSQL role: $DB_USER"
echo "Redis user: $REDIS_USER"
echo "Redis keys: $PROJECT:*"
echo "MinIO bucket: $MINIO_BUCKET"
echo "MinIO user: $MINIO_USER"
echo "MinIO policy: $MINIO_POLICY"
echo "==================================="

echo "WARNING: Project data will be permanently deleted."

read -r -p "Type DELETE $PROJECT to continue: " CONFIRM

if [ "$CONFIRM" != "DELETE $PROJECT" ]; then
    echo "Deletion cancelled."
    exit 1
fi

# Require a successful backup before deletion
echo "Creating backup before deletion..."

/opt/infra/backup/backup-all.sh

# Prevent new access during deletion
echo "[1/4] Disabling project access..."

pg -c "ALTER ROLE \"$DB_USER\" NOLOGIN;"

test "$(redis ACL SETUSER "$REDIS_USER" off)" = "OK"
test "$(redis ACL SAVE)" = "OK"

mc admin user disable deletion-local "$MINIO_USER"

# Delete PostgreSQL resources
echo "[2/4] Removing PostgreSQL resources..."

pg -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);"
pg -c "DROP ROLE IF EXISTS \"$DB_USER\";"

# Delete Redis resources
echo "[3/4] Removing Redis resources..."

redis --scan --pattern "$PROJECT:*" |
while IFS= read -r key; do
    [ -n "$key" ] || continue
    redis UNLINK "$key" >/dev/null
done

# Verify no matching keys remain
if [ -n "$(redis --scan --pattern "$PROJECT:*")" ]; then
    echo "Some Redis keys remain. Review manually."
    exit 1
fi

redis ACL DELUSER "$REDIS_USER"
test "$(redis ACL SAVE)" = "OK"

# Delete MinIO resources
echo "[4/4] Removing MinIO resources..."

mc admin policy detach \
    deletion-local \
    "$MINIO_POLICY" \
    --user "$MINIO_USER"

mc admin user remove \
    deletion-local \
    "$MINIO_USER"

mc rb --force \
    "deletion-local/$MINIO_BUCKET"

mc admin policy remove \
    deletion-local \
    "$MINIO_POLICY"

# Remove project credentials after successful deletion
rm -rf -- "$PROJECT_DIR"

echo "==================================="
echo "Project deleted successfully: $PROJECT"
echo "==================================="