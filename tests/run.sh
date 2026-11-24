#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local text="$1"
    local expected="$2"
    grep -Fq "$expected" <<< "$text" || fail "missing expected text: $expected"
}

echo "Testing interactive backup plans..."
output="$(bash "$REPO_DIR/scripts/setup-backup.sh" --plan fresh)"
assert_contains "$output" "optionally initialize"
output="$(bash "$REPO_DIR/scripts/setup-backup.sh" --plan restore)"
assert_contains "$output" "initialization and cron are disabled"

echo "Testing fresh Standalone installation plan..."
output="$(printf '1\ninfra.test.example\n1\nn\nn\ny\n' | bash "$REPO_DIR/scripts/bootstrap.sh" --plan)"
assert_contains "$output" "Deployment mode:  standalone"
assert_contains "$output" "no system changes were made"

echo "Testing GitOps restore preparation plan..."
output="$(printf '2\ninfra.test.example\n2\nn\nn\ny\n' | bash "$REPO_DIR/scripts/bootstrap.sh" --plan)"
assert_contains "$output" "Deployment mode:  gitops"
assert_contains "$output" "not started during restore preparation"

echo "Testing deployment mode validation..."
mkdir -p "$TEST_ROOT/config"
if DEPLOYMENT_CONFIG_FILE="$TEST_ROOT/config/missing.env" bash -c \
    'source "$1/scripts/lib/common.sh"; load_deployment_config' _ "$REPO_DIR" >/dev/null 2>&1; then
    fail "missing deployment configuration was accepted"
fi
printf 'DEPLOYMENT_MODE=invalid\n' > "$TEST_ROOT/config/deployment.env"
if DEPLOYMENT_CONFIG_FILE="$TEST_ROOT/config/deployment.env" bash -c \
    'source "$1/scripts/lib/common.sh"; load_deployment_config' _ "$REPO_DIR" >/dev/null 2>&1; then
    fail "invalid deployment mode was accepted"
fi

echo "Testing secret creation and preservation..."
ACME_EMAIL=test@example.com INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 \
    REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/setup-secrets.sh" --non-interactive
before="$(sha256sum "$TEST_ROOT/infra/secrets/database.env")"
ACME_EMAIL=changed@example.com POSTGRES_PASSWORD=attempted-rotation \
    INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/scripts/setup-secrets.sh" --non-interactive
after="$(sha256sum "$TEST_ROOT/infra/secrets/database.env")"
[ "$before" = "$after" ] || fail "existing database secrets were changed"

echo "Testing missing and complete Standalone configuration..."
printf 'INFRA_DOMAIN=infra.test.example\n' > "$TEST_ROOT/infra/infrastructure.env"
printf 'DEPLOYMENT_MODE=standalone\nREPOSITORY_DIR=%s\n' "$REPO_DIR" > "$TEST_ROOT/infra/deployment.env"
chmod 600 "$TEST_ROOT/infra/infrastructure.env" "$TEST_ROOT/infra/deployment.env"
INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/scripts/deploy.sh" --check >/dev/null

mv "$TEST_ROOT/infra/secrets/cache.env" "$TEST_ROOT/infra/secrets/cache.env.missing"
if INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/scripts/deploy.sh" --check >/dev/null 2>&1; then
    fail "missing cache secrets were accepted"
fi

echo "Testing project-name and ownership guards..."
for project in infra-gateway infra-database infra-cache infra-storage; do
    grep -Fq "$project" "$REPO_DIR/scripts/deploy.sh" || fail "missing Compose project name: $project"
done
grep -Fq 'docker container inspect dockhand' "$REPO_DIR/scripts/deploy.sh" ||
    fail "Dockhand ownership detection is missing"
grep -Fq 'infra-database_postgres_data' "$REPO_DIR/scripts/deploy.sh" ||
    fail "existing volume ownership detection is missing"
grep -Fq 'restore-prepared' "$REPO_DIR/scripts/deploy.sh" ||
    fail "explicit restore ownership exception is missing"
grep -Fq 'deployment-status' "$REPO_DIR/scripts/deploy.sh" ||
    fail "partial deployment status tracking is missing"
grep -Fq 'Dockhand is not installed; skipping' "$REPO_DIR/scripts/backup-infra.sh" ||
    fail "Standalone backup compatibility guard is missing"
grep -Fq 'refusing to create a duplicate' "$REPO_DIR/scripts/setup-cron.sh" ||
    fail "duplicate cron protection is missing"

echo "Testing backup lock inheritance and contention..."
grep -Fq 'acquire_destructive_project_locks' "$REPO_DIR/scripts/delete-project.sh" ||
    fail "delete-project does not use ordered destructive locks"
grep -Fq '/opt/infra/backup/backup-all.sh' "$REPO_DIR/scripts/delete-project.sh" ||
    fail "backup-before-delete is missing"
for component_script in backup-postgres.sh backup-redis.sh backup-minio.sh backup-infra.sh; do
    grep -Fq 'BACKUP_LOCK_HELD' "$REPO_DIR/scripts/$component_script" ||
        fail "$component_script cannot inherit the aggregate backup lock"
done
LOCK_BACKUP="$TEST_ROOT/lock-backup"
mkdir -p "$LOCK_BACKUP"
for component in postgres redis minio infra; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$LOCK_BACKUP/backup-$component.sh"
    chmod 700 "$LOCK_BACKUP/backup-$component.sh"
done
BACKUP_DIR="$LOCK_BACKUP" bash "$REPO_DIR/scripts/backup-all.sh" >/dev/null
(
    exec 8>"$LOCK_BACKUP/backup.lock"
    flock -n 8
    BACKUP_LOCK_HELD=1 BACKUP_DIR="$LOCK_BACKUP" \
        bash "$REPO_DIR/scripts/backup-all.sh" >/dev/null
)
(
    exec 8>"$LOCK_BACKUP/backup.lock"
    flock -n 8
    touch "$LOCK_BACKUP/ready"
    sleep 2
) &
LOCK_HOLDER=$!
while [ ! -f "$LOCK_BACKUP/ready" ]; do sleep 0.05; done
if BACKUP_DIR="$LOCK_BACKUP" bash "$REPO_DIR/scripts/backup-all.sh" \
    >"$LOCK_BACKUP/out" 2>"$LOCK_BACKUP/err"; then
    fail "contended backup lock was accepted"
fi
wait "$LOCK_HOLDER"
assert_contains "$(cat "$LOCK_BACKUP/err")" "Another backup"

echo "Testing fresh and restore backup setup with command mocks..."
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/rclone" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    listremotes) printf 'drive:\n' ;;
    lsd) exit 0 ;;
    config) exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$MOCK_BIN/restic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_RESTIC_LOG"
case " $* " in
    *" init "*) touch "$MOCK_RESTIC_INITIALIZED" ;;
    *" snapshots "*)
        if [ "${MOCK_RESTIC_MODE:-restore}" = "fresh" ] &&
           [ ! -f "$MOCK_RESTIC_INITIALIZED" ]; then
            exit 1
        fi
        echo "mock snapshot list"
        ;;
esac
EOF
chmod 700 "$MOCK_BIN/rclone" "$MOCK_BIN/restic"
printf '[drive]\ntype = drive\nscope = drive.file\n' > "$TEST_ROOT/import-rclone.conf"

SKIP_BACKUP_ROOT="$TEST_ROOT/skip-backup"
set +e
printf '3\n' | INFRA_ROOT="$SKIP_BACKUP_ROOT" INFRA_TEST_MODE=1 \
PATH="$MOCK_BIN:$PATH" bash "$REPO_DIR/scripts/setup-backup.sh" --fresh >/dev/null
SKIP_RESULT=$?
set -e
[ "$SKIP_RESULT" -eq 10 ] || fail "skipped backup setup returned an unexpected status"
[ ! -e "$SKIP_BACKUP_ROOT/backup/.env" ] || fail "skipped backup setup created credentials"

FRESH_BACKUP_ROOT="$TEST_ROOT/fresh-backup"
MOCK_RESTIC_LOG="$TEST_ROOT/fresh-restic.log" \
MOCK_RESTIC_INITIALIZED="$TEST_ROOT/fresh-initialized" \
MOCK_RESTIC_MODE=fresh INFRA_ROOT="$FRESH_BACKUP_ROOT" INFRA_TEST_MODE=1 \
PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_DIR/scripts/setup-backup.sh" --fresh <<EOF >/dev/null
2
$TEST_ROOT/import-rclone.conf
drive


2
INITIALIZE
EOF
grep -Fq 'init' "$TEST_ROOT/fresh-restic.log" || fail "fresh repository was not initialized after confirmation"

before="$(sha256sum "$FRESH_BACKUP_ROOT/backup/.env" "$FRESH_BACKUP_ROOT/backup/.restic-password" "$FRESH_BACKUP_ROOT/backup/rclone.conf")"
MOCK_RESTIC_LOG="$TEST_ROOT/verify-restic.log" \
MOCK_RESTIC_INITIALIZED="$TEST_ROOT/fresh-initialized" \
INFRA_ROOT="$FRESH_BACKUP_ROOT" INFRA_TEST_MODE=1 PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_DIR/scripts/setup-backup.sh" verify >/dev/null
after="$(sha256sum "$FRESH_BACKUP_ROOT/backup/.env" "$FRESH_BACKUP_ROOT/backup/.restic-password" "$FRESH_BACKUP_ROOT/backup/rclone.conf")"
[ "$before" = "$after" ] || fail "existing backup credentials were changed"

RESTORE_BACKUP_ROOT="$TEST_ROOT/restore-backup"
MOCK_RESTIC_LOG="$TEST_ROOT/restore-restic.log" \
MOCK_RESTIC_INITIALIZED="$TEST_ROOT/restore-initialized" \
MOCK_RESTIC_MODE=restore INFRA_ROOT="$RESTORE_BACKUP_ROOT" INFRA_TEST_MODE=1 \
PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_DIR/scripts/setup-backup.sh" --restore <<EOF >/dev/null
1
$TEST_ROOT/import-rclone.conf
drive
rclone:drive:existing-backup
source-host
existing-password
existing-password
EOF
if grep -Fq 'init' "$TEST_ROOT/restore-restic.log"; then
    fail "restore mode attempted to initialize a repository"
fi
grep -Fq 'snapshots' "$TEST_ROOT/restore-restic.log" || fail "restore mode did not list snapshots"

echo "All safe installer tests passed."
