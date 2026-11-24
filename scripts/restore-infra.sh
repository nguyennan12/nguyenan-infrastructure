#!/usr/bin/env bash

set -euo pipefail
umask 077

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/infrastructure-backup"
    exit 1
fi

BACKUP_DIR="$(realpath "$1")"

INFRA_DIR="/opt/infra"
PROJECTS_DIR="$INFRA_DIR/projects"

echo "===== Infrastructure restore started: $(date -Is) ====="

# Validate backup files
test -s "$BACKUP_DIR/volumes/dockhand.tar"
test -s "$BACKUP_DIR/volumes/traefik-certs.tar"

test -d "$BACKUP_DIR/config"
test -d "$BACKUP_DIR/config/backup"
test -d "$BACKUP_DIR/config/traefik"
test -d "$BACKUP_DIR/config/pgbouncer"

for file in .env .redis-password rclone.conf; do
    test -s "$BACKUP_DIR/config/backup/$file"
done

if [ ! -f "$BACKUP_DIR/config/infrastructure.env" ]; then
    echo "Note: infrastructure.env not found in backup (older backup snapshot)."
fi

# Prevent accidental restore on existing infrastructure
if [ -n "$(docker ps -aq)" ]; then
    echo "Existing Docker containers detected."
    echo "Restore requires a fresh recovery VPS."
    exit 1
fi

if [ -d "$PROJECTS_DIR" ] &&
   [ -n "$(ls -A "$PROJECTS_DIR")" ]; then
    echo "Existing project configurations detected."
    echo "Restore aborted."
    exit 1
fi

echo "WARNING: This operation restores infrastructure data."
echo "Only execute on a fresh recovery VPS."

read -r -p "Type RESTORE to continue: " CONFIRM

if [ "$CONFIRM" != "RESTORE" ]; then
    echo "Restore cancelled."
    exit 1
fi

# Restore Docker volume
restore_volume() {
    local volume="$1"
    local archive="$2"

    echo "Restoring volume: $volume"

    docker volume create "$volume" >/dev/null

    docker run --rm \
        -v "$volume:/target" \
        -v "$archive:/backup.tar:ro" \
        alpine:3.22 \
        sh -ec '
            if [ -n "$(ls -A /target)" ]; then
                echo "Target volume is not empty."
                exit 1
            fi

            tar -xpf /backup.tar -C /target
        '

    echo "Volume restored: $volume"
}

# Restore Dockhand data
echo "[1/5] Restoring Docker volumes..."

restore_volume \
    dockhand_data \
    "$BACKUP_DIR/volumes/dockhand.tar"

restore_volume \
    infra-gateway_traefik_certs \
    "$BACKUP_DIR/volumes/traefik-certs.tar"

# Prepare infrastructure directories
echo "[2/5] Preparing infrastructure directories..."

install -d -m 755 "$INFRA_DIR"
install -d -m 755 "$INFRA_DIR/traefik"
install -d -m 700 "$INFRA_DIR/pgbouncer"
install -d -m 700 "$INFRA_DIR/backup"
install -d -m 700 "$PROJECTS_DIR"

# Restore service configuration
echo "[3/5] Restoring service configurations..."

cp -a "$BACKUP_DIR/config/traefik/." \
    "$INFRA_DIR/traefik/"

cp -a "$BACKUP_DIR/config/pgbouncer/." \
    "$INFRA_DIR/pgbouncer/"

chmod -R go-rwx "$INFRA_DIR/pgbouncer"

# Restore backup credentials
echo "[4/5] Restoring backup credentials..."

for file in .env .redis-password rclone.conf; do
    install -m 600 \
        "$BACKUP_DIR/config/backup/$file" \
        "$INFRA_DIR/backup/$file"
done

# Restore project configurations
echo "[5/5] Restoring project configurations..."

if [ -d "$BACKUP_DIR/config/projects" ]; then

    cp -a "$BACKUP_DIR/config/projects/." \
        "$PROJECTS_DIR/"

    chmod -R go-rwx "$PROJECTS_DIR"

    find "$PROJECTS_DIR" -type d \
        -exec chmod 700 {} \;

    find "$PROJECTS_DIR" -type f \
        -exec chmod 600 {} \;

    echo "Project configurations restored."

else
    echo "No project configurations found in backup."
fi

# Restore infrastructure domain configuration
echo "[*] Handling infrastructure domain configuration..."

if [ -f "$INFRA_DIR/infrastructure.env" ]; then
    echo "Existing $INFRA_DIR/infrastructure.env detected on target host. Preserving existing configuration."
    echo "If you wish to use the domain from backup, inspect $BACKUP_DIR/config/infrastructure.env."
elif [ -f "$BACKUP_DIR/config/infrastructure.env" ]; then
    echo "Restoring infrastructure domain configuration from backup..."
    install -m 600 \
        "$BACKUP_DIR/config/infrastructure.env" \
        "$INFRA_DIR/infrastructure.env"
    chown root:root "$INFRA_DIR/infrastructure.env" 2>/dev/null || true
    echo "Infrastructure domain configuration restored."
else
    echo "Notice: infrastructure.env not found in backup or on host."
    echo "Please create $INFRA_DIR/infrastructure.env manually with:"
    echo "  INFRA_DOMAIN=<your-domain>"
    echo "and set permissions: chmod 600 $INFRA_DIR/infrastructure.env"
fi

echo "======================================"
echo "Infrastructure restore completed."
echo "======================================"

echo "Restored components:"
echo "- Dockhand data"
echo "- Traefik certificates"
echo "- Traefik configuration"
echo "- PgBouncer configuration"
echo "- Backup credentials"
echo "- Project configurations"
echo "- Infrastructure domain configuration (if present)"

echo ""
echo "Next steps:"
echo "1. Review restored configuration."
echo "2. Verify $INFRA_DIR/infrastructure.env matches your target domain."
echo "3. Verify Restic password is available."
echo "4. Restore PostgreSQL, Redis and MinIO."
echo "5. Start Dockhand and infrastructure stacks safely."
echo "6. Verify all services."
echo "7. Enable backup cron after recovery."

echo ""
echo "Cron has not been enabled."

echo "===== Infrastructure restore completed: $(date -Is) ====="