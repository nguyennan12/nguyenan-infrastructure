#!/usr/bin/env bash
set -euo pipefail
umask 077

INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
REPO_DIR="${REPO_DIR:-$INFRA_ROOT/repository}"
STATE_DIR="$INFRA_ROOT/state"
BACKUP_DIR="$INFRA_ROOT/backup"
SCRIPTS_DIR="$INFRA_ROOT/scripts"
MARKER="$STATE_DIR/last-sync-commit"
STATUS_FILE="$STATE_DIR/sync-status"
TRANSACTION="$STATE_DIR/sync-transaction"
TARGET_COMMIT="${INFRA_SYNC_TARGET_COMMIT:-}"
INSTALLED_COMMIT="$(cat "$MARKER" 2>/dev/null || true)"
STAGE=''
INSTALLING=false

status() {
    local value="$1" reason="${2:-}" tmp
    tmp="$(mktemp "$STATE_DIR/.sync-status.XXXXXX")" || return 1
    printf 'status=%s\ntarget=%s\ninstalled=%s\nupdated=%s\nreason=%s\n' \
        "$value" "$TARGET_COMMIT" "$INSTALLED_COMMIT" "$(date -u +%FT%TZ)" "$reason" > "$tmp"
    chmod 600 "$tmp"
    mv -fT "$tmp" "$STATUS_FILE"
}

recover() {
    local index destination backup failed=0
    [ -d "$TRANSACTION" ] || return 0
    if [ ! -s "$TRANSACTION/plan" ]; then
        status recovery-required 'transaction plan missing' || true
        return 1
    fi
    while IFS=$'\t' read -r index destination; do
        [ -n "$index" ] || continue
        if [ -f "$TRANSACTION/old/$index" ]; then
            backup="$(mktemp "${destination}.rollback.XXXXXX")" || { failed=1; continue; }
            if ! cp -p "$TRANSACTION/old/$index" "$backup" || ! mv -fT "$backup" "$destination"; then
                rm -f -- "$backup"; failed=1
            fi
        elif [ -f "$TRANSACTION/new/$index" ]; then
            rm -f -- "$destination" || failed=1
        else
            failed=1
        fi
    done < "$TRANSACTION/plan"
    if [ "$failed" -ne 0 ]; then
        status recovery-required 'rollback incomplete; inspect sync-transaction' || true
        echo 'Rollback incomplete; preserve sync-transaction and recover manually.' >&2
        return 1
    fi
    if [ -f "$TRANSACTION/previous-commit" ]; then
        local marker_tmp
        marker_tmp="$(mktemp "$STATE_DIR/.last-sync-commit.XXXXXX")" || return 1
        cp "$TRANSACTION/previous-commit" "$marker_tmp"
        mv -fT "$marker_tmp" "$MARKER"
    else
        rm -f -- "$MARKER"
    fi
    rm -rf -- "$TRANSACTION"
    status failed 'installation rolled back' || true
}

on_exit() {
    local rc="$?"
    trap - EXIT
    if $INSTALLING && [ -d "$TRANSACTION" ]; then
        recover || rc=1
    elif [ "$rc" -ne 0 ] && [ ! -d "$TRANSACTION" ]; then
        status failed 'validation or worker execution failed' || true
    fi
    [ -z "$STAGE" ] || rm -rf -- "$STAGE"
    exit "$rc"
}
trap on_exit EXIT

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != 1 ]; then
    echo 'Please run with sudo.' >&2; exit 1
fi
install -d -m 700 "$STATE_DIR" "$BACKUP_DIR" "$SCRIPTS_DIR"
exec 9>"$STATE_DIR/sync.lock"
if ! flock -n 9; then status postponed 'another sync is running' || true; echo 'Sync postponed: another sync is running.'; exit 0; fi
if [ -d "$TRANSACTION" ]; then
    echo 'Recovering interrupted synchronization before new work.' >&2
    recover || exit 1
    exit 1
fi
[ -d "$REPO_DIR/.git" ] || { echo 'Infrastructure repository not found.' >&2; exit 1; }
if [ -z "$TARGET_COMMIT" ]; then
    git -C "$REPO_DIR" fetch --no-tags origin production
    TARGET_COMMIT="$(git -C "$REPO_DIR" rev-parse --verify 'FETCH_HEAD^{commit}')"
fi
[[ "$TARGET_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid target commit.' >&2; exit 1; }
git -C "$REPO_DIR" cat-file -e "$TARGET_COMMIT^{commit}"
if [ "$TARGET_COMMIT" = "$INSTALLED_COMMIT" ]; then status up-to-date; exit 0; fi

# Preserve the existing lock order: backup then provisioning. Both are
# nonblocking, so a busy runtime is retried by the next timer invocation.
exec 8>"$BACKUP_DIR/backup.lock"
if ! flock -n 8; then status postponed 'backup lock busy' || true; echo 'Backup in progress. Sync postponed.'; exit 0; fi
exec 7>"$STATE_DIR/provisioning.lock"
if ! flock -n 7; then status postponed 'provisioning lock busy' || true; echo 'Project operation in progress. Sync postponed.'; exit 0; fi

status validating
STAGE="$(mktemp -d "$STATE_DIR/sync-stage.XXXXXX")"
git -C "$REPO_DIR" archive "$TARGET_COMMIT" | tar -x -C "$STAGE"
REGISTRY_ROOT="$STAGE/registry"
REGISTRY_TRUSTED_ROOT="$STAGE"
export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT INFRA_ROOT
source "$STAGE/scripts/core/registry.sh"
registry_validate
find "$STAGE/scripts" -type f -name '*.sh' -print0 | xargs -0 -r -n1 bash -n

declare -a SOURCES=() DESTINATIONS=()
declare -A SEEN=()
add_file() {
    local source="$1" destination="$2" resolved
    [ -f "$STAGE/$source" ] || { echo "Missing source: $source" >&2; return 1; }
    resolved="$(realpath "$STAGE/$source")" || return 1
    case "$resolved" in "$STAGE/"*) ;; *) echo "Source escapes staging: $source" >&2; return 1 ;; esac
    case "$destination" in
        "$INFRA_ROOT/scripts/"*|"$INFRA_ROOT/backup/"*|"$INFRA_ROOT/registry/"*|"$INFRA_ROOT/stacks/"*|"$INFRA_ROOT/monitoring/"*) ;;
        *) echo "Unsafe destination: $destination" >&2; return 1 ;;
    esac
    [ "$destination" != "$INFRA_ROOT/bin/sync-infra.sh" ] || return 1
    [ -z "${SEEN[$destination]:-}" ] || { echo "Duplicate destination: $destination" >&2; return 1; }
    SEEN[$destination]=1
    SOURCES+=("$source") DESTINATIONS+=("$destination")
}

for name in backup-all backup-infra maintenance; do
    add_file "scripts/backup/$name.sh" "$BACKUP_DIR/$name.sh"
done
while IFS=$'\t' read -r source destination; do
    add_file "$source" "$SCRIPTS_DIR/$destination"
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
add_file scripts/core/common.sh "$SCRIPTS_DIR/core/common.sh"
add_file scripts/core/registry.sh "$SCRIPTS_DIR/core/registry.sh"
for name in monitor checks notify; do
    add_file "scripts/monitoring/$name.sh" "$INFRA_ROOT/monitoring/$name.sh"
done
while IFS=$'\t' read -r source destination; do
    [ -n "$source" ] || continue
    [[ "$destination" =~ ^(scripts/services/[a-z0-9-]+/(adapter|provision)\.sh|scripts/restore-[a-z0-9-]+\.sh|backup/backup-[a-z0-9-]+\.sh)$ ]] || {
        echo "Unsafe registry destination: $destination" >&2; exit 1;
    }
    add_file "$source" "$INFRA_ROOT/$destination"
done < <(registry_sync_manifest)
while IFS= read -r compose_file; do
    [[ "$compose_file" =~ ^stacks/[a-z0-9-]+\.yml$ ]] || exit 1
    add_file "$compose_file" "$INFRA_ROOT/$compose_file"
done < <(jq -r '.stacks[].compose_file' "$REGISTRY_ROOT/stacks.json" | sort -u)
add_file registry/stacks.json "$INFRA_ROOT/registry/stacks.json"
add_file registry/services.json "$INFRA_ROOT/registry/services.json"

# Prepare all payloads and rollback data before the first runtime replacement.
install -d -m 700 "$STAGE/payload" "$STAGE/old" "$STAGE/new"
: > "$STAGE/plan"
if [ -f "$MARKER" ]; then cp -p "$MARKER" "$STAGE/previous-commit"; fi
for i in "${!SOURCES[@]}"; do
    destination="${DESTINATIONS[$i]}"
    [[ "$destination" != *'/../'* && "$destination" != *'/./'* ]] || exit 1
    install -m 700 "$STAGE/${SOURCES[$i]}" "$STAGE/payload/$i"
    if [ -e "$destination" ]; then
        [ -f "$destination" ] && [ ! -L "$destination" ] || { echo "Unsafe existing destination: $destination" >&2; exit 1; }
        cp -p "$destination" "$STAGE/old/$i"
    else
        : > "$STAGE/new/$i"
    fi
    printf '%s\t%s\n' "$i" "$destination" >> "$STAGE/plan"
done
mv "$STAGE" "$TRANSACTION"
STAGE=''
INSTALLING=true
status syncing
for i in "${!SOURCES[@]}"; do
    destination="${DESTINATIONS[$i]}"
    install -d -m 700 "$(dirname "$destination")"
    temporary="$(mktemp "${destination}.sync.XXXXXX")"
    install -m 700 "$TRANSACTION/payload/$i" "$temporary"
    case "$destination" in "$INFRA_ROOT/registry/"*|"$INFRA_ROOT/stacks/"*) chmod 600 "$temporary" ;; esac
    mv -fT "$temporary" "$destination"
done
for i in "${!SOURCES[@]}"; do
    cmp -s "$TRANSACTION/payload/$i" "${DESTINATIONS[$i]}" || { echo "Post-install verification failed: ${DESTINATIONS[$i]}" >&2; exit 1; }
done
temporary="$(mktemp "$STATE_DIR/.last-sync-commit.XXXXXX")"
printf '%s\n' "$TARGET_COMMIT" > "$temporary"
chmod 600 "$temporary"
mv -fT "$temporary" "$MARKER"
INSTALLED_COMMIT="$TARGET_COMMIT"
INSTALLING=false
rm -rf -- "$TRANSACTION"
status synchronized
echo "Synchronized commit: $TARGET_COMMIT"

echo "Versioned worker automatic update: PASS"
