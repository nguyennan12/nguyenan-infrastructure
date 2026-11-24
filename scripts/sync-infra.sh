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

BACKUP_SCRIPTS=(
    backup-all.sh
    backup-infra.sh
    backup-postgres.sh
    backup-redis.sh
    backup-minio.sh
    maintenance.sh
)

for script in "${BACKUP_SCRIPTS[@]}"; do
    install_script \
        "$REPO_DIR/scripts/$script" \
        "$BACKUP_DIR/$script"
done

echo "Synchronizing management scripts..."

MANAGEMENT_SCRIPTS=(
    bootstrap.sh
    setup-system.sh
    setup-docker.sh
    setup-network.sh
    setup-directories.sh
    setup-cockpit.sh
    setup-dockhand.sh
    setup-backup.sh
    setup-cron.sh
    setup-minio-client.sh
    setup-secrets.sh
    deploy.sh
    update.sh
    create-project.sh
    list-projects.sh
    delete-project.sh
    add-service.sh
    remove-service.sh
    restore-all.sh
    restore-infra.sh
    restore-postgres.sh
    restore-redis.sh
    restore-minio.sh
)

for script in "${MANAGEMENT_SCRIPTS[@]}"; do
    install_script \
        "$REPO_DIR/scripts/$script" \
        "$SCRIPTS_DIR/$script"
done

echo "Synchronizing provisioning modules..."

install -d -m 700 "$SCRIPTS_DIR/lib"

MODULES=(
    common.sh
    postgres.sh
    redis.sh
    minio.sh
)

for module in "${MODULES[@]}"; do
    install_script \
        "$REPO_DIR/scripts/lib/$module" \
        "$SCRIPTS_DIR/lib/$module"
done

printf '%s\n' "$REMOTE_COMMIT" \
    > "$STATE_DIR/last-sync-commit"

echo "Synchronized commit: $REMOTE_COMMIT"
echo "===== Infrastructure sync completed ====="
