#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"
STAGING="$BASE/staging/infrastructure"
PROJECTS_DIR="/opt/infra/projects"
DOCKHAND_WAS_RUNNING=false

source "$BASE/.env"

if [ "${BACKUP_LOCK_HELD:-0}" != "1" ]; then
    exec 9>"$BASE/backup.lock"
    flock -n 9 || { echo "Another backup, deployment or infrastructure update is running." >&2; exit 1; }
fi

echo "===== Infrastructure backup started: $(date -Is) ====="

cleanup() {
    if [ "$DOCKHAND_WAS_RUNNING" = "true" ]; then
        docker start dockhand >/dev/null 2>&1 || true
    fi
    rm -rf -- "$STAGING"
}

trap cleanup EXIT

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

# Backup Dockhand only when it is installed. Standalone mode has no such volume.
if docker container inspect dockhand >/dev/null 2>&1 &&
   docker volume inspect dockhand_data >/dev/null 2>&1; then
    echo "Backing up Dockhand..."
    DOCKHAND_PATH=$(docker volume inspect -f '{{.Mountpoint}}' dockhand_data)
    DOCKHAND_WAS_RUNNING="$(docker inspect -f '{{.State.Running}}' dockhand)"

    if [ "$DOCKHAND_WAS_RUNNING" = "true" ]; then
        docker stop dockhand
    fi

    tar -cf "$STAGING/volumes/dockhand.tar" -C "$DOCKHAND_PATH" .

    if [ "$DOCKHAND_WAS_RUNNING" = "true" ]; then
        docker start dockhand
        DOCKHAND_WAS_RUNNING=false
    fi
else
    echo "Dockhand is not installed; skipping its optional data volume."
fi

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

if [ -f /opt/infra/deployment.env ]; then
    echo "Backing up deployment ownership configuration..."
    install -m 600 /opt/infra/deployment.env "$STAGING/config/deployment.env"
fi

if [ -d /opt/infra/secrets ]; then
    echo "Backing up portable stack secrets inside the encrypted repository..."
    cp -a /opt/infra/secrets "$STAGING/config/secrets"
    chmod -R go-rwx "$STAGING/config/secrets"
fi

if [ -d /opt/infra/registry ]; then
    echo "Backing up validated infrastructure registry..."
    cp -a /opt/infra/registry "$STAGING/config/registry"
    chmod -R go-rwx "$STAGING/config/registry"
fi

if [ -d /opt/infra/stacks ]; then
    cp -a /opt/infra/stacks "$STAGING/config/registered-stacks"
    chmod -R go-rwx "$STAGING/config/registered-stacks"
fi

if [ -d /opt/infra/scripts/services ]; then
    cp -a /opt/infra/scripts/services "$STAGING/config/service-adapters"
    chmod -R go-rwx "$STAGING/config/service-adapters"
fi

if [ -s /opt/infra/monitoring/.discord-webhook ]; then
    install -d -m 700 "$STAGING/config/monitoring"
    install -m 600 /opt/infra/monitoring/.discord-webhook "$STAGING/config/monitoring/.discord-webhook"
    for unit in infra-monitor.service infra-monitor.timer; do
        if [ -f "/etc/systemd/system/$unit" ]; then
            install -m 600 "/etc/systemd/system/$unit" "$STAGING/config/monitoring/$unit"
        fi
    done
fi

# Recovery references for the GitOps controller; transient locks and workers
# are deliberately excluded from the encrypted infrastructure snapshot.
if [ -f /opt/infra/bin/sync-infra.sh ]; then
    install -d -m 700 "$STAGING/config/gitops"
    install -m 700 /opt/infra/bin/sync-infra.sh "$STAGING/config/gitops/sync-launcher.sh"
    for unit in infra-sync.service infra-sync.timer; do
        if [ -f "/etc/systemd/system/$unit" ]; then
            install -m 600 "/etc/systemd/system/$unit" "$STAGING/config/gitops/$unit"
        fi
    done
    if [ -f /opt/infra/state/last-sync-commit ]; then
        install -m 600 /opt/infra/state/last-sync-commit "$STAGING/config/gitops/last-sync-commit"
    fi
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
trap - EXIT

echo "===== Infrastructure backup completed: $(date -Is) ====="
