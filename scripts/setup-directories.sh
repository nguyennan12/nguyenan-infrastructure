#!/usr/bin/env bash
set -euo pipefail

echo "[4/4] Setting up directories..."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install -d -m 755 /opt/infra
install -d -m 700 /opt/infra/backup
install -d -m 755 /opt/infra/traefik/dynamic
install -d -m 755 /opt/infra/pgbouncer

# Copy Traefik configuration
install -m 644 \
    "$ROOT_DIR/configs/traefik/dynamic/tls.yml" \
    /opt/infra/traefik/dynamic/tls.yml

# Copy PgBouncer authentication setup
install -m 644 \
    "$ROOT_DIR/configs/pgbouncer/setup-auth.sql" \
    /opt/infra/pgbouncer/setup-auth.sql

# Copy backup scripts
for script in \
    backup-all.sh \
    backup-infra.sh \
    backup-postgres.sh \
    backup-redis.sh \
    backup-minio.sh \
    maintenance.sh
do
    install -m 700 \
        "$ROOT_DIR/scripts/$script" \
        "/opt/infra/backup/$script"
done

echo "Directories setup completed."