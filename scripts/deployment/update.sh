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
REPO_DIR_EXPLICIT="${REPO_DIR:-}"
if [ -d "$INFRA_ROOT/repository/.git" ]; then
    DEFAULT_REPO_DIR="$INFRA_ROOT/repository"
else
    DEFAULT_REPO_DIR="$(cd "$SCRIPTS_ROOT/.." && pwd)"
fi
REPO_DIR="${REPO_DIR:-$DEFAULT_REPO_DIR}"
STATE_DIR="$INFRA_ROOT/state"
DEPLOYMENT_CONFIG_FILE="${DEPLOYMENT_CONFIG_FILE:-$INFRA_ROOT/deployment.env}"

source "$SCRIPTS_ROOT/core/common.sh"

if [ -z "$REPO_DIR_EXPLICIT" ]; then
    CONFIGURED_REPO="$(read_config_value "$DEPLOYMENT_CONFIG_FILE" REPOSITORY_DIR || true)"
    [ -z "$CONFIGURED_REPO" ] || REPO_DIR="$CONFIGURED_REPO"
fi

require_root
load_deployment_config
[ "$DEPLOYMENT_MODE" = "standalone" ] || {
    echo "update.sh is available only in Standalone mode." >&2
    exit 1
}

test -d "$REPO_DIR/.git"
if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    echo "Local repository modifications detected; update aborted." >&2
    exit 1
fi

BRANCH="$(read_config_value "$DEPLOYMENT_CONFIG_FILE" STANDALONE_BRANCH || true)"
[ -n "$BRANCH" ] || {
    echo "STANDALONE_BRANCH is required in deployment.env." >&2
    exit 1
}
if [[ ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$BRANCH" == -* ]]; then
    echo "Invalid STANDALONE_BRANCH." >&2
    exit 1
fi

install -d -m 700 "$STATE_DIR"
exec 9>"$STATE_DIR/deployment.lock"
flock -n 9 || {
    echo "Another deployment or update is running." >&2
    exit 1
}

install -d -m 700 "$INFRA_ROOT/backup"
exec 8>"$INFRA_ROOT/backup/backup.lock"
exec 7>"$STATE_DIR/provisioning.lock"
exec 6>"$STATE_DIR/restore.lock"
flock -n 8 && flock -n 7 && flock -n 6 || {
    echo "A backup, restore or project operation is running." >&2
    exit 1
}

REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/deployment/deploy.sh" --check

git -C "$REPO_DIR" fetch origin "$BRANCH"
TARGET_COMMIT="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
CURRENT_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"

if [ "$TARGET_COMMIT" = "$CURRENT_COMMIT" ]; then
    echo "Standalone infrastructure is already at the configured revision."
    exit 0
fi

VALIDATION_DIR="$(mktemp -d "$STATE_DIR/update-validation.XXXXXX")"
cleanup() {
    git -C "$REPO_DIR" worktree remove --force "$VALIDATION_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git -C "$REPO_DIR" worktree add --detach "$VALIDATION_DIR" "$TARGET_COMMIT" >/dev/null

find "$VALIDATION_DIR/scripts" -type f -name '*.sh' -print0 |
    xargs -0 -r -n1 bash -n

INFRA_TEST_MODE=1 REPO_DIR="$VALIDATION_DIR" \
    bash "$VALIDATION_DIR/scripts/deployment/deploy.sh" --check >/dev/null

while IFS=$'\t' read -r project compose_file secret_file; do
    secret="$INFRA_ROOT/secrets/$secret_file"
    docker compose --project-name "$project" \
        --env-file "$INFRA_ROOT/infrastructure.env" \
        --env-file "$secret" \
        --file "$VALIDATION_DIR/$compose_file" config --quiet
done < <(jq -r '.stacks[] | select(.enabled == true) | [.project_name, .compose_file, .secret_file] | @tsv' \
    "$VALIDATION_DIR/registry/stacks.json")

printf '%s\n' "$CURRENT_COMMIT" > "$STATE_DIR/previous-deployed-commit"
git -C "$REPO_DIR" checkout --detach "$TARGET_COMMIT"

INFRA_DEPLOY_LOCK_HELD=1 INFRA_OPERATION_LOCKS_HELD=1 \
    REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/deployment/deploy.sh"

printf '%s\n' "$TARGET_COMMIT" > "$STATE_DIR/last-deployed-commit"
echo "Standalone update completed: $TARGET_COMMIT"
