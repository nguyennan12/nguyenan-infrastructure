#!/usr/bin/env bash
set -euo pipefail
umask 077

INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
REPO_DIR="${REPO_DIR:-$INFRA_ROOT/repository}"
STATE_DIR="$INFRA_ROOT/state"
STATUS_FILE="$STATE_DIR/sync-status"
MARKER="$STATE_DIR/last-sync-commit"

write_status() {
    local status="$1" reason="${2:-}" tmp
    tmp="$(mktemp "$STATE_DIR/.sync-status.XXXXXX")" || return 1
    printf 'status=%s\ntarget=%s\ninstalled=%s\nupdated=%s\nreason=%s\n' \
        "$status" "${TARGET_COMMIT:-}" "${INSTALLED_COMMIT:-}" "$(date -u +%FT%TZ)" "$reason" > "$tmp"
    chmod 600 "$tmp"
    mv -fT "$tmp" "$STATUS_FILE"
}

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != 1 ]; then
    echo 'Please run with sudo.' >&2; exit 1
fi
install -d -m 700 "$STATE_DIR"
exec 9>"$STATE_DIR/sync-launcher.lock"
if ! flock -n 9; then
    echo 'Another sync launcher is running; postponed.' >&2
    exit 0
fi
INSTALLED_COMMIT="$(cat "$MARKER" 2>/dev/null || true)"
TARGET_COMMIT=''
if [ -f "$STATUS_FILE" ] && grep -q '^status=recovery-required$' "$STATUS_FILE"; then
    echo 'Previous synchronization requires manual recovery; see sync-status.' >&2
    exit 1
fi
if [ ! -d "$REPO_DIR/.git" ]; then
    write_status failed 'repository missing' || true
    echo 'Infrastructure repository not found.' >&2; exit 1
fi
write_status fetching
if ! git -C "$REPO_DIR" fetch --no-tags origin production; then
    write_status failed 'git fetch failed' || true
    echo 'Production fetch failed.' >&2; exit 1
fi
TARGET_COMMIT="$(git -C "$REPO_DIR" rev-parse --verify 'FETCH_HEAD^{commit}')"
if [ "$TARGET_COMMIT" = "$INSTALLED_COMMIT" ]; then
    write_status up-to-date
    echo "Infrastructure scripts are up to date: $TARGET_COMMIT"
    exit 0
fi
WORKER="$(mktemp "$STATE_DIR/.sync-worker.XXXXXX")"
trap 'rm -f -- "$WORKER"' EXIT
if ! git -C "$REPO_DIR" show "$TARGET_COMMIT:scripts/deployment/sync-infra.sh" > "$WORKER" || [ ! -s "$WORKER" ]; then
    write_status failed 'worker missing or empty' || true
    echo 'Versioned sync worker is missing or empty.' >&2; exit 1
fi
chmod 700 "$WORKER"
if ! bash -n "$WORKER"; then
    write_status failed 'worker syntax invalid' || true
    echo 'Versioned sync worker has invalid Bash syntax.' >&2; exit 1
fi
# The worker owns sync.lock, backup.lock and provisioning.lock. The launcher
# holds only its independent lock, avoiding recursive acquisition.
if ! INFRA_SYNC_TARGET_COMMIT="$TARGET_COMMIT" bash "$WORKER"; then
    echo 'Versioned sync worker failed; inspect sync-status.' >&2
    exit 1
fi
