#!/bin/bash

set -euo pipefail
umask 077

BASE="/opt/infra/backup"
STAGING="$BASE/staging/infrastructure"

source "$BASE/.env"

exec 9>"$BASE/backup.lock"
flock -n 9 || exit 1

echo "===== Infrastructure backup started: $(date -Is) ====="

rm -rf "$STAGING"
mkdir -p "$STAGING/docker"
mkdir -p "$STAGING/config"
mkdir -p "$STAGING/volumes"

# Export Docker configuration
docker ps -a > "$STAGING/docker/containers.txt"

docker inspect $(docker ps -aq) \
  > "$STAGING/docker/containers.json"

docker network inspect $(docker network ls -q) \
  > "$STAGING/docker/networks.json"

docker volume inspect $(docker volume ls -q) \
  > "$STAGING/docker/volumes.json"

docker images --digests \
  > "$STAGING/docker/images.txt"

# Backup Dockhand consistently
DOCKHAND_PATH=$(docker volume inspect \
  -f '{{.Mountpoint}}' dockhand_data)

trap 'docker start dockhand >/dev/null 2>&1 || true' EXIT

docker stop dockhand

tar -cf "$STAGING/volumes/dockhand.tar" \
  -C "$DOCKHAND_PATH" .

docker start dockhand

trap - EXIT

# Backup Traefik certificates
CERT_PATH=$(docker volume inspect \
  -f '{{.Mountpoint}}' infra-gateway_traefik_certs)

tar -cf "$STAGING/volumes/traefik-certs.tar" \
  -C "$CERT_PATH" .

# Backup Traefik configuration
cp -a /opt/infra/traefik \
  "$STAGING/config/traefik"

# Backup PgBouncer configuration
docker cp infra-pgbouncer:/etc/pgbouncer \
  "$STAGING/config/pgbouncer"

# Backup scripts and settings
mkdir -p "$STAGING/config/backup"

cp "$BASE"/*.sh \
  "$STAGING/config/backup/"

cp "$BASE/.env" \
  "$BASE/.redis-password" \
  "$BASE/rclone.conf" \
  "$STAGING/config/backup/"

crontab -l > "$STAGING/config/crontab.txt"

# Upload encrypted backup
restic -o rclone.timeout=5m \
  --compression off \
  backup "$STAGING" \
  --tag infrastructure

# Cleanup
rm -rf "$STAGING"

echo "===== Infrastructure backup completed: $(date -Is) ====="
