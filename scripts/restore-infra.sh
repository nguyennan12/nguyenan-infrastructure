#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/infrastructure-backup"
    exit 1
fi

BACKUP_DIR="$(realpath "$1")"

umask 077

test -s "$BACKUP_DIR/volumes/dockhand.tar"
test -s "$BACKUP_DIR/volumes/traefik-certs.tar"
test -d "$BACKUP_DIR/config"

# Restore before creating service containers
if [ -n "$(docker ps -aq)" ]; then
    echo "Existing Docker containers detected."
    echo "Restore requires a fresh recovery VPS."
    exit 1
fi

read -r -p "Type RESTORE to continue: " CONFIRM
[ "$CONFIRM" = "RESTORE" ] || exit 1

restore_volume() {
    local volume="$1"
    local archive="$2"

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

    echo "Restored volume: $volume"
}

echo "Restoring Docker volumes..."

restore_volume \
    dockhand_data \
    "$BACKUP_DIR/volumes/dockhand.tar"

restore_volume \
    infra-gateway_traefik_certs \
    "$BACKUP_DIR/volumes/traefik-certs.tar"

echo "Restoring infrastructure configuration..."

install -d -m 755 /opt/infra/traefik
install -d -m 700 /opt/infra/pgbouncer
install -d -m 700 /opt/infra/backup

cp -a "$BACKUP_DIR/config/traefik/." \
    /opt/infra/traefik/

cp -a "$BACKUP_DIR/config/pgbouncer/." \
    /opt/infra/pgbouncer/

# Restore backup credentials without replacing newer scripts
for file in .env .redis-password rclone.conf; do
    install -m 600 \
        "$BACKUP_DIR/config/backup/$file" \
        "/opt/infra/backup/$file"
done

echo "Infrastructure restore completed."
echo "Review configuration before deploying containers."
echo "Cron has not been enabled."