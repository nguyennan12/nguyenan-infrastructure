#!/usr/bin/env bash
set -euo pipefail

echo "[4/4] Setting up directories..."

ROOT_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REGISTRY_ROOT="$ROOT_DIR/registry"
REGISTRY_TRUSTED_ROOT="$ROOT_DIR"
export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT
source "$ROOT_DIR/scripts/core/registry.sh"
registry_validate

for required_source in \
    scripts/bootstrap.sh \
    scripts/core/common.sh \
    scripts/core/registry.sh \
    scripts/backup/backup-all.sh \
    scripts/backup/backup-infra.sh \
    scripts/backup/maintenance.sh \
    scripts/setup/setup-system.sh \
    scripts/setup/setup-docker.sh \
    scripts/setup/setup-network.sh \
    scripts/setup/setup-directories.sh \
    scripts/setup/setup-cockpit.sh \
    scripts/setup/setup-dockhand.sh \
    scripts/setup/setup-backup.sh \
    scripts/setup/setup-cron.sh \
    scripts/setup/setup-minio-client.sh \
    scripts/setup/setup-secrets.sh \
    scripts/deployment/deploy.sh \
    scripts/deployment/update.sh \
    scripts/deployment/sync-launcher.sh \
    scripts/deployment/sync-infra.sh \
    scripts/projects/orchestrator.sh \
    scripts/projects/list-services.sh \
    scripts/projects/create-project.sh \
    scripts/projects/list-projects.sh \
    scripts/projects/delete-project.sh \
    scripts/projects/add-service.sh \
    scripts/projects/remove-service.sh \
    scripts/restore/restore-all.sh \
    scripts/restore/restore-infra.sh
do
    [ -f "$ROOT_DIR/$required_source" ] || {
        echo "Required source file is missing: $required_source" >&2
        exit 1
    }
done

install -d -m 755 /opt/infra
install -d -m 700 /opt/infra/backup
install -d -m 700 /opt/infra/secrets
install -d -m 700 /opt/infra/projects
install -d -m 700 /opt/infra/state
install -d -m 700 /opt/infra/scripts
install -d -m 755 /opt/infra/registry
install -d -m 755 /opt/infra/stacks
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

# Keep existing cron command targets stable.
install -m 700 "$ROOT_DIR/scripts/backup/backup-all.sh" /opt/infra/backup/backup-all.sh
install -m 700 "$ROOT_DIR/scripts/backup/backup-infra.sh" /opt/infra/backup/backup-infra.sh
install -m 700 "$ROOT_DIR/scripts/backup/maintenance.sh" /opt/infra/backup/maintenance.sh

# Install management scripts for Standalone use and recovery. GitOps may later
# update the same allowlisted files through sync-infra.sh.
while IFS=$'\t' read -r source destination; do
    install -m 700 "$ROOT_DIR/$source" "/opt/infra/scripts/$destination"
done <<'EOF'
scripts/bootstrap.sh	bootstrap.sh
scripts/setup/setup-system.sh	setup-system.sh
scripts/setup/setup-docker.sh	setup-docker.sh
scripts/setup/setup-network.sh	setup-network.sh
scripts/setup/setup-directories.sh	setup-directories.sh
scripts/setup/setup-cockpit.sh	setup-cockpit.sh
scripts/setup/setup-dockhand.sh	setup-dockhand.sh
scripts/setup/setup-backup.sh	setup-backup.sh
scripts/setup/setup-cron.sh	setup-cron.sh
scripts/setup/setup-minio-client.sh	setup-minio-client.sh
scripts/setup/setup-secrets.sh	setup-secrets.sh
scripts/deployment/deploy.sh	deploy.sh
scripts/deployment/update.sh	update.sh
scripts/projects/orchestrator.sh	project-services.sh
scripts/projects/list-services.sh	list-services.sh
scripts/projects/create-project.sh	create-project.sh
scripts/projects/list-projects.sh	list-projects.sh
scripts/projects/delete-project.sh	delete-project.sh
scripts/projects/add-service.sh	add-service.sh
scripts/projects/remove-service.sh	remove-service.sh
scripts/restore/restore-all.sh	restore-all.sh
scripts/restore/restore-infra.sh	restore-infra.sh
EOF

install -d -m 700 /opt/infra/scripts/core
install -m 700 "$ROOT_DIR/scripts/core/common.sh" /opt/infra/scripts/core/common.sh
install -m 700 "$ROOT_DIR/scripts/core/registry.sh" /opt/infra/scripts/core/registry.sh

while IFS=$'\t' read -r source destination; do
    destination_path="/opt/infra/$destination"
    install -d -m 700 "$(dirname "$destination_path")"
    install -m 700 "$ROOT_DIR/$source" "$destination_path"
done < <(registry_sync_manifest)

install -m 600 "$ROOT_DIR/registry/stacks.json" /opt/infra/registry/stacks.json
install -m 600 "$ROOT_DIR/registry/services.json" /opt/infra/registry/services.json
while IFS= read -r stack_file; do
    install -m 600 "$ROOT_DIR/$stack_file" "/opt/infra/$stack_file"
done < <(jq -r '.stacks[].compose_file' "$ROOT_DIR/registry/stacks.json" | sort -u)

echo "Directories setup completed."
