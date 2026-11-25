#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
source "$SCRIPTS_ROOT/core/common.sh"

CONTAINER="infra-postgres"
DB_USER="infra_admin"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

acquire_restore_locks

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/postgres.sql"
    exit 1
fi

DUMP_FILE="$1"

if [ ! -s "$DUMP_FILE" ]; then
    echo "Backup file not found or empty."
    exit 1
fi

docker exec "$CONTAINER" pg_isready -U "$DB_USER"

DB_COUNT=$(docker exec "$CONTAINER" \
    psql -U "$DB_USER" -d postgres -Atc \
    "SELECT count(*) FROM pg_database
     WHERE datname NOT IN
     ('postgres', 'template0', 'template1');")

if [ "$DB_COUNT" != "0" ]; then
    echo "Existing databases detected. Restore aborted."
    exit 1
fi

echo "Restore only to a fresh recovery instance."
read -r -p "Type RESTORE to continue: " CONFIRM

if [ "$CONFIRM" != "RESTORE" ]; then
    exit 1
fi

# pg_dumpall may recreate the bootstrap admin role.
# Remove only its duplicate CREATE ROLE statement.
sed '/^CREATE ROLE infra_admin;$/d' "$DUMP_FILE" |
    docker exec -i "$CONTAINER" \
        psql -X -v ON_ERROR_STOP=1 \
        -U "$DB_USER" -d postgres

echo "PostgreSQL restore completed."

docker exec "$CONTAINER" \
    psql -U "$DB_USER" -d postgres -c '\l'

docker exec "$CONTAINER" \
    psql -U "$DB_USER" -d postgres -c '\du'
