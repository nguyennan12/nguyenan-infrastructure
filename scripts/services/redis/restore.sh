#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
source "$SCRIPTS_ROOT/core/common.sh"

CONTAINER="infra-redis"
VOLUME="infra-cache_redis_data"
IMAGE="redis:8-alpine"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

acquire_restore_locks

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 redis.rdb users.acl"
    exit 1
fi

RDB_FILE="$(realpath "$1")"
ACL_FILE="$(realpath "$2")"

test -s "$RDB_FILE"
test -s "$ACL_FILE"

if docker container inspect "$CONTAINER" \
    >/dev/null 2>&1; then
    echo "Redis container already exists."
    echo "Restore before deploying Redis."
    exit 1
fi

docker volume create "$VOLUME"

docker run --rm \
    -v "$VOLUME:/data" \
    -v "$RDB_FILE:/restore/dump.rdb:ro" \
    -v "$ACL_FILE:/restore/users.acl:ro" \
    --entrypoint sh \
    "$IMAGE" -ec '
        if [ -n "$(ls -A /data)" ]; then
            echo "Volume is not empty. Restore aborted."
            exit 1
        fi

        redis-check-rdb /restore/dump.rdb

        cp /restore/dump.rdb /data/dump.rdb
        cp /restore/users.acl /data/users.acl

        chown redis:redis \
            /data/dump.rdb \
            /data/users.acl

        chmod 600 \
            /data/dump.rdb \
            /data/users.acl
    '

echo "Redis files restored successfully."
echo "Start Redis with AOF disabled initially."
