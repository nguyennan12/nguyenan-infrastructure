#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
BACKUP_DIR="$INFRA_ROOT/backup"
BACKUP_ENV="$BACKUP_DIR/.env"
RCLONE_FILE="$BACKUP_DIR/rclone.conf"
PASSWORD_FILE="$BACKUP_DIR/.restic-password"
MODE="${1:-verify}"

source "$SCRIPTS_ROOT/core/common.sh"

if [ "$MODE" = "--plan" ]; then
    case "${2:-}" in
        fresh)
            echo "Fresh backup plan: configure or import Rclone, create/preserve a Restic password, verify access, optionally initialize an explicitly confirmed new repository, then enable cron."
            ;;
        restore)
            echo "Restore backup plan: import existing Rclone credentials, existing Restic URL and password, verify access and list snapshots. Repository initialization and cron are disabled."
            ;;
        *) echo "Usage: $0 --plan fresh|restore" >&2; exit 1 ;;
    esac
    exit 0
fi

case "$MODE" in
    verify|--fresh|--restore) ;;
    *) echo "Usage: $0 [verify|--fresh|--restore|--plan fresh|restore]" >&2; exit 1 ;;
esac

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != "1" ]; then
    echo "Please run with sudo."
    exit 1
fi

command -v rclone >/dev/null
command -v restic >/dev/null
install -d -m 700 "$BACKUP_DIR"
[ "$EUID" -ne 0 ] || chown root:root "$BACKUP_DIR"

exec 9>"$BACKUP_DIR/backup.lock"
flock -n 9 || {
    echo "Another backup, deployment or infrastructure update is running." >&2
    exit 1
}

for protected_file in "$BACKUP_ENV" "$RCLONE_FILE" "$PASSWORD_FILE"; do
    if [ -e "$protected_file" ] && [ ! -s "$protected_file" ]; then
        echo "Existing backup credential/configuration file is empty; refusing to overwrite it: $protected_file" >&2
        exit 1
    fi
done

validate_remote_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]]
}

verify_files() {
    local file
    for file in "$BACKUP_ENV" "$PASSWORD_FILE" "$RCLONE_FILE"; do
        if [ ! -s "$file" ]; then
            echo "Missing backup configuration: $file" >&2
            return 1
        fi
        chmod 600 "$file"
        [ "$EUID" -ne 0 ] || chown root:root "$file"
    done
}

load_backup_values() {
    RESTIC_REPOSITORY_VALUE="$(read_config_value "$BACKUP_ENV" RESTIC_REPOSITORY || true)"
    RCLONE_CONFIG_VALUE="$(read_config_value "$BACKUP_ENV" RCLONE_CONFIG || true)"
    RESTIC_PASSWORD_FILE_VALUE="$(read_config_value "$BACKUP_ENV" RESTIC_PASSWORD_FILE || true)"
    SOURCE_HOST_VALUE="$(read_config_value "$BACKUP_ENV" SOURCE_HOST || true)"

    [ -n "$RESTIC_REPOSITORY_VALUE" ] || { echo "RESTIC_REPOSITORY is missing." >&2; return 1; }
    [ -s "$RCLONE_CONFIG_VALUE" ] || { echo "Configured RCLONE_CONFIG file is missing." >&2; return 1; }
    [ -s "$RESTIC_PASSWORD_FILE_VALUE" ] || { echo "Configured RESTIC_PASSWORD_FILE is missing." >&2; return 1; }
    [ -n "$SOURCE_HOST_VALUE" ] || { echo "SOURCE_HOST is missing." >&2; return 1; }
}

restic_snapshots() {
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY_VALUE" \
    RCLONE_CONFIG="$RCLONE_CONFIG_VALUE" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE_VALUE" \
        restic -o rclone.timeout=5m snapshots
}

if [ "$MODE" = "verify" ]; then
    verify_files
    load_backup_values
    echo "Checking backup repository..."
    restic_snapshots
    echo "Backup configuration verified."
    exit 0
fi

echo "Backup configuration:"
if [ "$MODE" = "--fresh" ]; then
    echo "  1. Configure Google Drive interactively"
    echo "  2. Import an existing rclone.conf"
else
    echo "  1. Import an existing rclone.conf"
fi
echo "  3. Skip and configure backup later"
read -r -p "Selection: " RCLONE_CHOICE

if [ "$RCLONE_CHOICE" = "3" ]; then
    echo "Backup configuration skipped. No credentials or schedules were changed."
    exit 10
fi

if [ "$MODE" = "--fresh" ]; then
    [[ "$RCLONE_CHOICE" =~ ^[12]$ ]] || { echo "Invalid backup configuration selection." >&2; exit 1; }
else
    [ "$RCLONE_CHOICE" = "1" ] || { echo "Invalid backup configuration selection." >&2; exit 1; }
fi

if [ -s "$RCLONE_FILE" ]; then
    echo "Existing rclone.conf detected; preserving it."
else
    case "$MODE:$RCLONE_CHOICE" in
        --fresh:1)
            echo "Rclone will open its interactive configuration."
            echo "Create a Google Drive remote, optionally enter a custom OAuth Client ID/Secret, select drive.file scope, and use the browser/headless authorization flow shown by Rclone."
            RCLONE_CONFIG="$RCLONE_FILE" rclone config
            ;;
        --fresh:2|--restore:1)
            read -r -p "Path to existing rclone.conf: " IMPORT_FILE
            IMPORT_FILE="$(realpath "$IMPORT_FILE")"
            [ -s "$IMPORT_FILE" ] || { echo "Imported rclone.conf is missing or empty." >&2; exit 1; }
            install -m 600 "$IMPORT_FILE" "$RCLONE_FILE"
            ;;
        *) echo "Invalid backup configuration selection." >&2; exit 1 ;;
    esac
fi

chmod 600 "$RCLONE_FILE"
[ "$EUID" -ne 0 ] || chown root:root "$RCLONE_FILE"

read -r -p "Rclone remote name: " RCLONE_REMOTE
validate_remote_name "$RCLONE_REMOTE" || { echo "Invalid Rclone remote name." >&2; exit 1; }

if ! RCLONE_CONFIG="$RCLONE_FILE" rclone listremotes | grep -Fxq "$RCLONE_REMOTE:"; then
    echo "Rclone remote was not found in the imported/configured file." >&2
    exit 1
fi

echo "Verifying Google Drive access..."
RCLONE_CONFIG="$RCLONE_FILE" rclone lsd "$RCLONE_REMOTE:" >/dev/null

if [ -s "$BACKUP_ENV" ]; then
    echo "Existing backup environment detected; preserving it."
else
    if [ "$MODE" = "--fresh" ]; then
        read -r -p "Backup repository folder [infra-backup]: " REPOSITORY_FOLDER
        REPOSITORY_FOLDER="${REPOSITORY_FOLDER:-infra-backup}"
        if [[ ! "$REPOSITORY_FOLDER" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
           [[ "$REPOSITORY_FOLDER" == *..* ]]; then
            echo "Invalid backup repository folder." >&2
            exit 1
        fi
        DEFAULT_REPOSITORY="rclone:${RCLONE_REMOTE}:${REPOSITORY_FOLDER}"
        read -r -p "Restic repository URL [$DEFAULT_REPOSITORY]: " RESTIC_REPOSITORY_VALUE
        RESTIC_REPOSITORY_VALUE="${RESTIC_REPOSITORY_VALUE:-$DEFAULT_REPOSITORY}"
        SOURCE_HOST_VALUE="$(hostname -s)"
    else
        read -r -p "Existing Restic repository URL: " RESTIC_REPOSITORY_VALUE
        read -r -p "Source host stored in snapshots: " SOURCE_HOST_VALUE
    fi

    if [ -z "$RESTIC_REPOSITORY_VALUE" ] || [[ "$RESTIC_REPOSITORY_VALUE" =~ [[:space:]] ]]; then
        echo "Invalid Restic repository URL." >&2
        exit 1
    fi
    if [[ ! "$SOURCE_HOST_VALUE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
        echo "Invalid source host." >&2
        exit 1
    fi

    {
        printf 'RESTIC_REPOSITORY=%s\n' "$RESTIC_REPOSITORY_VALUE"
        printf 'RCLONE_CONFIG=%s\n' "$RCLONE_FILE"
        printf 'RESTIC_PASSWORD_FILE=%s\n' "$PASSWORD_FILE"
        printf 'SOURCE_HOST=%s\n' "$SOURCE_HOST_VALUE"
    } > "$BACKUP_ENV"
    chmod 600 "$BACKUP_ENV"
    [ "$EUID" -ne 0 ] || chown root:root "$BACKUP_ENV"
fi

if [ -s "$PASSWORD_FILE" ]; then
    echo "Existing Restic password detected; preserving it."
elif [ "$MODE" = "--restore" ]; then
    read -r -s -p "Existing Restic password: " RESTIC_PASSWORD_ONE
    echo
    read -r -s -p "Confirm existing Restic password: " RESTIC_PASSWORD_TWO
    echo
    [ -n "$RESTIC_PASSWORD_ONE" ] && [ "$RESTIC_PASSWORD_ONE" = "$RESTIC_PASSWORD_TWO" ] || {
        echo "Restic passwords do not match." >&2
        exit 1
    }
    printf '%s\n' "$RESTIC_PASSWORD_ONE" > "$PASSWORD_FILE"
    unset RESTIC_PASSWORD_ONE RESTIC_PASSWORD_TWO
else
    echo "Restic password:"
    echo "  1. Enter an existing/new password securely"
    echo "  2. Generate a strong password"
    read -r -p "Selection: " PASSWORD_CHOICE
    case "$PASSWORD_CHOICE" in
        1)
            read -r -s -p "Restic password: " RESTIC_PASSWORD_ONE
            echo
            read -r -s -p "Confirm Restic password: " RESTIC_PASSWORD_TWO
            echo
            [ -n "$RESTIC_PASSWORD_ONE" ] && [ "$RESTIC_PASSWORD_ONE" = "$RESTIC_PASSWORD_TWO" ] || {
                echo "Restic passwords do not match." >&2
                exit 1
            }
            printf '%s\n' "$RESTIC_PASSWORD_ONE" > "$PASSWORD_FILE"
            unset RESTIC_PASSWORD_ONE RESTIC_PASSWORD_TWO
            ;;
        2)
            openssl rand -base64 36 | tr -d '\n' > "$PASSWORD_FILE"
            printf '\n' >> "$PASSWORD_FILE"
            echo "A strong Restic password was generated without printing it."
            echo "Store it outside the VPS in a password manager before relying on this backup."
            echo "Retrieve it only from a private terminal: sudo cat $PASSWORD_FILE"
            ;;
        *) echo "Invalid password selection." >&2; exit 1 ;;
    esac
fi

chmod 600 "$PASSWORD_FILE"
[ "$EUID" -ne 0 ] || chown root:root "$PASSWORD_FILE"
verify_files
load_backup_values

echo "Verifying Restic repository access..."
if ! restic_snapshots; then
    if [ "$MODE" = "--restore" ]; then
        echo "Existing repository verification failed. Restore mode will never initialize a repository." >&2
        exit 1
    fi

    echo "Repository access failed. Initialization is allowed only for a confirmed new destination."
    read -r -p "Type INITIALIZE to create a new Restic repository, or press Enter to abort: " CONFIRM_INIT
    [ "$CONFIRM_INIT" = "INITIALIZE" ] || exit 1
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY_VALUE" \
    RCLONE_CONFIG="$RCLONE_CONFIG_VALUE" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE_VALUE" \
        restic -o rclone.timeout=5m init
    restic_snapshots
fi

if [ "$MODE" = "--restore" ]; then
    echo "Existing backup repository verified; available snapshots are listed above."
    echo "No repository was initialized and no backup schedule was enabled."
else
    echo "Backup repository verified. The caller may now enable the backup schedule."
fi
