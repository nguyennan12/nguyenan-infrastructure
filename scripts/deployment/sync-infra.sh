#!/usr/bin/env bash

set -euo pipefail
umask 077

REPO_DIR="/opt/infra/repository"
BACKUP_DIR="/opt/infra/backup"
SCRIPTS_DIR="/opt/infra/scripts"
STATE_DIR="/opt/infra/state"
BRANCH="production"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

install -d -m 700 "$STATE_DIR"
install -d -m 700 "$SCRIPTS_DIR"
install -d -m 700 "$BACKUP_DIR"

exec 9>"$STATE_DIR/sync.lock"
flock -n 9 || {
    echo "Another infrastructure sync is already running."
    exit 0
}

echo "===== Infrastructure sync: $(date -Is) ====="

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "Infrastructure repository not found."
    exit 1
fi

# Fetch validated production branch
git -C "$REPO_DIR" fetch origin "$BRANCH"

REMOTE_COMMIT=$(git -C "$REPO_DIR" \
    rev-parse "origin/$BRANCH")

LOCAL_COMMIT=""

if [ -f "$STATE_DIR/last-sync-commit" ]; then
    LOCAL_COMMIT=$(cat "$STATE_DIR/last-sync-commit")
fi

if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo "Infrastructure scripts are up to date."
    exit 0
fi

# Update dedicated repository checkout
git -C "$REPO_DIR" checkout --detach "$REMOTE_COMMIT"

echo "Validating shell scripts..."

find "$REPO_DIR/scripts" \
    -type f -name '*.sh' -print0 |
    xargs -0 -r -n1 bash -n

REGISTRY_ROOT="$REPO_DIR/registry"
REGISTRY_TRUSTED_ROOT="$REPO_DIR"
INFRA_ROOT="/opt/infra"
export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT INFRA_ROOT
source "$REPO_DIR/scripts/core/registry.sh"
registry_validate

# Validate every static source before changing an installed runtime file. This
# also makes the repository layout transition fail closed on an incomplete tree.
STATIC_SOURCES=(
    scripts/bootstrap.sh
    scripts/core/common.sh
    scripts/core/registry.sh
    scripts/backup/backup-all.sh
    scripts/backup/backup-infra.sh
    scripts/backup/maintenance.sh
    scripts/setup/setup-system.sh
    scripts/setup/setup-docker.sh
    scripts/setup/setup-network.sh
    scripts/setup/setup-directories.sh
    scripts/setup/setup-cockpit.sh
    scripts/setup/setup-dockhand.sh
    scripts/setup/setup-backup.sh
    scripts/setup/setup-cron.sh
    scripts/setup/setup-minio-client.sh
    scripts/setup/setup-secrets.sh
    scripts/deployment/deploy.sh
    scripts/deployment/update.sh
    scripts/projects/orchestrator.sh
    scripts/projects/list-services.sh
    scripts/projects/create-project.sh
    scripts/projects/list-projects.sh
    scripts/projects/delete-project.sh
    scripts/projects/add-service.sh
    scripts/projects/remove-service.sh
    scripts/restore/restore-all.sh
    scripts/restore/restore-infra.sh
)
for source in "${STATIC_SOURCES[@]}"; do
    [ -f "$REPO_DIR/$source" ] || {
        echo "Required source file is missing: $source" >&2
        exit 1
    }
done

# Avoid updating scripts during an active backup
exec 8>"$BACKUP_DIR/backup.lock"
flock -n 8 || {
    echo "Backup in progress. Sync postponed."
    exit 0
}

# Replace files atomically
install_script() {
    local source="$1"
    local destination="$2"
    local temporary

    temporary=$(mktemp "${destination}.XXXXXX")

    install -m 700 "$source" "$temporary"
    mv -fT "$temporary" "$destination"
}

exec 7>"$STATE_DIR/provisioning.lock"

flock -n 7 || {
    echo "Project operation in progress. Sync postponed."
    exit 0
}

echo "Synchronizing backup scripts..."

install_script "$REPO_DIR/scripts/backup/backup-all.sh" "$BACKUP_DIR/backup-all.sh"
install_script "$REPO_DIR/scripts/backup/backup-infra.sh" "$BACKUP_DIR/backup-infra.sh"
install_script "$REPO_DIR/scripts/backup/maintenance.sh" "$BACKUP_DIR/maintenance.sh"

echo "Synchronizing management scripts..."

while IFS=$'\t' read -r source destination; do
    install_script "$REPO_DIR/$source" "$SCRIPTS_DIR/$destination"
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

echo "Synchronizing provisioning modules..."

install -d -m 700 "$SCRIPTS_DIR/core"
install_script "$REPO_DIR/scripts/core/common.sh" "$SCRIPTS_DIR/core/common.sh"
install_script "$REPO_DIR/scripts/core/registry.sh" "$SCRIPTS_DIR/core/registry.sh"

echo "Synchronizing registered service files..."

while IFS=$'\t' read -r source destination; do
    source_path="$(registry_resolve_path "$source")"
    destination_path="/opt/infra/$destination"

    case "$destination" in
        scripts/services/*/*.sh|scripts/restore-*.sh)
            [[ "$destination" =~ ^scripts/(services/[a-z0-9-]+/(adapter|provision)\.sh|restore-[a-z0-9-]+\.sh)$ ]] || exit 1
            install -d -m 700 "$(dirname "$destination_path")"
            ;;
        backup/backup-*.sh)
            [[ "$destination" =~ ^backup/backup-[a-z0-9-]+\.sh$ ]] || exit 1
            install -d -m 700 "$BACKUP_DIR"
            ;;
        *)
            echo "Unsafe registered installation destination: $destination" >&2
            exit 1
            ;;
    esac

    install_script "$source_path" "$destination_path"
done < <(registry_sync_manifest)

echo "Synchronizing registered Compose definitions for runtime validation..."
install -d -m 755 /opt/infra/stacks
while IFS= read -r compose_file; do
    [[ "$compose_file" =~ ^stacks/[a-z0-9-]+\.yml$ ]] || exit 1
    install_script "$REPO_DIR/$compose_file" "/opt/infra/$compose_file"
    chmod 600 "/opt/infra/$compose_file"
done < <(jq -r '.stacks[].compose_file' "$REPO_DIR/registry/stacks.json" | sort -u)

# Install registry metadata last so runtime never observes metadata before its
# required registered files have been installed successfully.
install -d -m 755 /opt/infra/registry
install_script "$REPO_DIR/registry/stacks.json" /opt/infra/registry/stacks.json
install_script "$REPO_DIR/registry/services.json" /opt/infra/registry/services.json
chmod 600 /opt/infra/registry/stacks.json /opt/infra/registry/services.json

printf '%s\n' "$REMOTE_COMMIT" \
    > "$STATE_DIR/last-sync-commit"

echo "Synchronized commit: $REMOTE_COMMIT"
echo "===== Infrastructure sync completed ====="
