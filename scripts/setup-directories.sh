#!/usr/bin/env bash
set -euo pipefail

echo "[4/4] Setting up directories..."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install -d -m 755 /opt/infra
install -d -m 700 /opt/infra/backup
install -d -m 700 /opt/infra/secrets
install -d -m 700 /opt/infra/projects
install -d -m 700 /opt/infra/state
install -d -m 700 /opt/infra/scripts
install -d -m 755 /opt/infra/traefik/dynamic
install -d -m 755 /opt/infra/pgbouncer

# Infrastructure environment configuration template
if [ ! -f /opt/infra/infrastructure.env ]; then
    if [ -f "$ROOT_DIR/infrastructure.env.example" ]; then
        install -m 600 \
            "$ROOT_DIR/infrastructure.env.example" \
            /opt/infra/infrastructure.env
        echo "Created /opt/infra/infrastructure.env from example template."
        echo "IMPORTANT: Update /opt/infra/infrastructure.env with your actual domain."
    fi
else
    echo "Preserving existing /opt/infra/infrastructure.env."
    chmod 600 /opt/infra/infrastructure.env
fi

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

# Install management scripts for Standalone use and recovery. GitOps may later
# update the same allowlisted files through sync-infra.sh.
for script in \
    bootstrap.sh \
    setup-system.sh \
    setup-docker.sh \
    setup-network.sh \
    setup-directories.sh \
    setup-cockpit.sh \
    setup-dockhand.sh \
    setup-backup.sh \
    setup-cron.sh \
    setup-minio-client.sh \
    setup-secrets.sh \
    deploy.sh \
    update.sh \
    create-project.sh \
    list-projects.sh \
    delete-project.sh \
    add-service.sh \
    remove-service.sh \
    restore-all.sh \
    restore-infra.sh \
    restore-postgres.sh \
    restore-redis.sh \
    restore-minio.sh
do
    install -m 700 "$ROOT_DIR/scripts/$script" "/opt/infra/scripts/$script"
done

install -d -m 700 /opt/infra/scripts/lib
for module in common.sh postgres.sh redis.sh minio.sh; do
    install -m 700 "$ROOT_DIR/scripts/lib/$module" "/opt/infra/scripts/lib/$module"
done

echo "Directories setup completed."
