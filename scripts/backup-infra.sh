#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"
STAGING="$BASE/staging/infrastructure"
PROJECTS_DIR="/opt/infra/projects"

source "$BASE/.env"

exec 9>"$BASE/backup.lock"
flock -n 9 || exit 1

echo "===== Infrastructure backup started: $(date -Is) ====="

rm -rf "$STAGING"

mkdir -p "$STAGING/docker"
mkdir -p "$STAGING/config"
mkdir -p "$STAGING/volumes"

# Export Docker configuration
echo "Exporting Docker configuration..."

docker ps -a \
    > "$STAGING/docker/containers.txt"

docker ps -aq |
    xargs -r docker inspect \
    > "$STAGING/docker/containers.json"

docker network ls -q |
    xargs -r docker network inspect \
    > "$STAGING/docker/networks.json"

docker volume ls -q |
    xargs -r docker volume inspect \
    > "$STAGING/docker/volumes.json"

docker images --digests \
    > "$STAGING/docker/images.txt"

# Backup Dockhand consistently
echo "Backing up Dockhand..."

DOCKHAND_PATH=$(docker volume inspect \
    -f '{{.Mountpoint}}' dockhand_data)

trap 'docker start dockhand >/dev/null 2>&1 || true' EXIT

docker stop dockhand

tar -cf "$STAGING/volumes/dockhand.tar" \
    -C "$DOCKHAND_PATH" .

docker start dockhand

trap - EXIT

# Backup Traefik certificates
echo "Backing up Traefik certificates..."

CERT_PATH=$(docker volume inspect \
    -f '{{.Mountpoint}}' infra-gateway_traefik_certs)

tar -cf "$STAGING/volumes/traefik-certs.tar" \
    -C "$CERT_PATH" .

# Backup Traefik configuration
echo "Backing up Traefik configuration..."

cp -a /opt/infra/traefik \
    "$STAGING/config/traefik"

# Backup PgBouncer configuration
echo "Backing up PgBouncer configuration..."

docker cp infra-pgbouncer:/etc/pgbouncer \
    "$STAGING/config/pgbouncer"

# Backup scripts and settings
echo "Backing up automation scripts and settings..."

mkdir -p "$STAGING/config/backup"

cp "$BASE"/*.sh \
    "$STAGING/config/backup/"

cp "$BASE/.env" \
    "$BASE/.redis-password" \
    "$BASE/rclone.conf" \
    "$STAGING/config/backup/"

# Backup infrastructure domain configuration
if [ -f /opt/infra/infrastructure.env ]; then
    echo "Backing up infrastructure environment configuration..."
    install -m 600 /opt/infra/infrastructure.env "$STAGING/config/infrastructure.env"
else
    echo "Warning: /opt/infra/infrastructure.env not found. Skipping."
fi

# Backup project credentials and policies
if [ -d "$PROJECTS_DIR" ]; then
    echo "Backing up project configurations..."

    cp -a "$PROJECTS_DIR" \
        "$STAGING/config/projects"

    chmod -R go-rwx "$STAGING/config/projects"
else
    echo "No project configurations found. Skipping."
fi

# Backup cron configuration
echo "Backing up cron configuration..."

if ! crontab -l > "$STAGING/config/crontab.txt"; then
    echo "No root crontab found."
fi

if [ -f /etc/cron.d/infra-backup ]; then
    cp /etc/cron.d/infra-backup \
        "$STAGING/config/infra-backup.cron"
fi

# Upload encrypted backup
echo "Uploading encrypted infrastructure backup..."

restic -o rclone.timeout=5m \
    --compression off \
    backup "$STAGING" \
    --tag infrastructure

# Cleanup
rm -rf "$STAGING"

echo "===== Infrastructure backup completed: $(date -Is) ====="