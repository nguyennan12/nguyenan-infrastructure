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
output="$(bash "$REPO_DIR/scripts/setup/setup-backup.sh" --plan fresh)"
assert_contains "$output" "optionally initialize"
output="$(bash "$REPO_DIR/scripts/setup/setup-backup.sh" --plan restore)"
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
    'source "$1/scripts/core/common.sh"; load_deployment_config' _ "$REPO_DIR" >/dev/null 2>&1; then
    fail "missing deployment configuration was accepted"
fi
printf 'DEPLOYMENT_MODE=invalid\n' > "$TEST_ROOT/config/deployment.env"
if DEPLOYMENT_CONFIG_FILE="$TEST_ROOT/config/deployment.env" bash -c \
    'source "$1/scripts/core/common.sh"; load_deployment_config' _ "$REPO_DIR" >/dev/null 2>&1; then
    fail "invalid deployment mode was accepted"
fi

echo "Testing secret creation and preservation..."
ACME_EMAIL=test@example.com INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 \
    REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/setup/setup-secrets.sh" --non-interactive
before="$(sha256sum "$TEST_ROOT/infra/secrets/database.env")"
ACME_EMAIL=changed@example.com POSTGRES_PASSWORD=attempted-rotation \
    INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/scripts/setup/setup-secrets.sh" --non-interactive
after="$(sha256sum "$TEST_ROOT/infra/secrets/database.env")"
[ "$before" = "$after" ] || fail "existing database secrets were changed"

echo "Testing missing and complete Standalone configuration..."
printf 'INFRA_DOMAIN=infra.test.example\n' > "$TEST_ROOT/infra/infrastructure.env"
printf 'DEPLOYMENT_MODE=standalone\nREPOSITORY_DIR=%s\n' "$REPO_DIR" > "$TEST_ROOT/infra/deployment.env"
chmod 600 "$TEST_ROOT/infra/infrastructure.env" "$TEST_ROOT/infra/deployment.env"
INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/scripts/deployment/deploy.sh" --check >/dev/null

mv "$TEST_ROOT/infra/secrets/cache.env" "$TEST_ROOT/infra/secrets/cache.env.missing"
if INFRA_ROOT="$TEST_ROOT/infra" INFRA_TEST_MODE=1 REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/scripts/deployment/deploy.sh" --check >/dev/null 2>&1; then
    fail "missing cache secrets were accepted"
fi

echo "Testing project-name and ownership guards..."
for project in infra-gateway infra-database infra-cache infra-storage; do
    jq -e --arg project "$project" '.stacks[] | select(.project_name == $project)' \
        "$REPO_DIR/registry/stacks.json" >/dev/null || fail "missing Compose project name: $project"
done
grep -Fq 'docker container inspect dockhand' "$REPO_DIR/scripts/deployment/deploy.sh" ||
    fail "Dockhand ownership detection is missing"
jq -e '.stacks[] | select(.volumes | index("infra-database_postgres_data"))' \
    "$REPO_DIR/registry/stacks.json" >/dev/null || fail "existing volume registration is missing"
grep -Fq 'restore-prepared' "$REPO_DIR/scripts/deployment/deploy.sh" ||
    fail "explicit restore ownership exception is missing"
grep -Fq 'deployment-status' "$REPO_DIR/scripts/deployment/deploy.sh" ||
    fail "partial deployment status tracking is missing"
grep -Fq 'Dockhand is not installed; skipping' "$REPO_DIR/scripts/backup/backup-infra.sh" ||
    fail "Standalone backup compatibility guard is missing"
grep -Fq 'refusing to create a duplicate' "$REPO_DIR/scripts/setup/setup-cron.sh" ||
    fail "duplicate cron protection is missing"

echo "Testing registry validation and extensibility fixture..."
bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null
FIXTURE_ROOT="$REPO_DIR/tests/fixtures/extensibility"
REGISTRY_ROOT="$FIXTURE_ROOT/registry" REGISTRY_TRUSTED_ROOT="$FIXTURE_ROOT" \
    bash -c 'source "$1/scripts/core/registry.sh"; registry_validate; test "$(registry_stack_order)" = mock-stack; test "$(registry_backup_services)" = mock-service; test "$(registry_sync_manifest | wc -l)" -eq 3' _ "$REPO_DIR"
output="$(REGISTRY_ROOT="$FIXTURE_ROOT/registry" REGISTRY_TRUSTED_ROOT="$FIXTURE_ROOT" \
    bash "$REPO_DIR/scripts/projects/list-services.sh")"
assert_contains "$output" "mock-service"

REGISTRY_ROOT="$FIXTURE_ROOT/registry" REGISTRY_TRUSTED_ROOT="$FIXTURE_ROOT" bash -c '
    source "$1/scripts/core/registry.sh"
    registry_validate
    registry_run_service_hook mock-service health
' _ "$REPO_DIR"

PROJECT_RUNTIME="$TEST_ROOT/project-runtime"
printf 'CREATE demo\n' | INFRA_ROOT="$PROJECT_RUNTIME" INFRA_TEST_MODE=1 \
MOCK_HOOK_LOG="$TEST_ROOT/project-hook.log" REGISTRY_ROOT="$FIXTURE_ROOT/registry" \
REGISTRY_TRUSTED_ROOT="$FIXTURE_ROOT" \
    bash "$REPO_DIR/scripts/projects/orchestrator.sh" create demo --services mock-service >/dev/null
jq -e '.status == "provisioned" and .services["mock-service"] == true' \
    "$PROJECT_RUNTIME/projects/demo/project.json" >/dev/null || fail "dynamic project service selection failed"

make_invalid_registry() {
    local name="$1"
    local jq_filter="$2"
    local invalid_root="$TEST_ROOT/$name"
    mkdir -p "$invalid_root"
    cp -a "$FIXTURE_ROOT/." "$invalid_root/"
    jq "$jq_filter" "$invalid_root/registry/services.json" > "$invalid_root/registry/services.tmp"
    mv "$invalid_root/registry/services.tmp" "$invalid_root/registry/services.json"
    printf '%s\n' "$invalid_root"
}

INVALID_ROOT="$(make_invalid_registry duplicate-service '.services += [.services[0]]')"
if REGISTRY_ROOT="$INVALID_ROOT/registry" REGISTRY_TRUSTED_ROOT="$INVALID_ROOT" \
    bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null 2>&1; then
    fail "duplicate service identifier was accepted"
fi

MISSING_DEP_ROOT="$(make_invalid_registry missing-dependency '.services[0].dependencies = ["absent-service"]')"
if REGISTRY_ROOT="$MISSING_DEP_ROOT/registry" REGISTRY_TRUSTED_ROOT="$MISSING_DEP_ROOT" \
    bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null 2>&1; then
    fail "missing service dependency was accepted"
fi

CYCLE_ROOT="$TEST_ROOT/cycle"
cp -a "$FIXTURE_ROOT/." "$CYCLE_ROOT/"
jq '.stacks[0].dependencies = ["mock-stack"]' "$CYCLE_ROOT/registry/stacks.json" > "$CYCLE_ROOT/registry/stacks.tmp"
mv "$CYCLE_ROOT/registry/stacks.tmp" "$CYCLE_ROOT/registry/stacks.json"
if REGISTRY_ROOT="$CYCLE_ROOT/registry" REGISTRY_TRUSTED_ROOT="$CYCLE_ROOT" \
    bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null 2>&1; then
    fail "stack dependency cycle was accepted"
fi

SERVICE_CYCLE_ROOT="$TEST_ROOT/service-cycle"
cp -a "$FIXTURE_ROOT/." "$SERVICE_CYCLE_ROOT/"
jq '.services[0].dependencies = ["mock-service"]' "$SERVICE_CYCLE_ROOT/registry/services.json" > "$SERVICE_CYCLE_ROOT/registry/services.tmp"
mv "$SERVICE_CYCLE_ROOT/registry/services.tmp" "$SERVICE_CYCLE_ROOT/registry/services.json"
if REGISTRY_ROOT="$SERVICE_CYCLE_ROOT/registry" REGISTRY_TRUSTED_ROOT="$SERVICE_CYCLE_ROOT" \
    bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null 2>&1; then
    fail "service dependency cycle was accepted"
fi

UNSAFE_ROOT="$(make_invalid_registry unsafe-path '.services[0].module = "../escape.sh"')"
if REGISTRY_ROOT="$UNSAFE_ROOT/registry" REGISTRY_TRUSTED_ROOT="$UNSAFE_ROOT" \
    bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null 2>&1; then
    fail "unsafe registry path was accepted"
fi

MISSING_HOOK_ROOT="$TEST_ROOT/missing-hook"
cp -a "$FIXTURE_ROOT/." "$MISSING_HOOK_ROOT/"
mkdir -p "$MISSING_HOOK_ROOT/scripts/services/incomplete"
printf '#!/usr/bin/env bash\nservice_validate_configuration() { return 0; }\n' \
    > "$MISSING_HOOK_ROOT/scripts/services/incomplete/adapter.sh"
jq '.services[0].module = "scripts/services/incomplete/adapter.sh"' \
    "$MISSING_HOOK_ROOT/registry/services.json" > "$MISSING_HOOK_ROOT/registry/services.tmp"
mv "$MISSING_HOOK_ROOT/registry/services.tmp" "$MISSING_HOOK_ROOT/registry/services.json"
if REGISTRY_ROOT="$MISSING_HOOK_ROOT/registry" REGISTRY_TRUSTED_ROOT="$MISSING_HOOK_ROOT" \
    bash "$REPO_DIR/scripts/validation/validate-registry.sh" >/dev/null 2>&1; then
    fail "missing standardized hooks were accepted"
fi

DISABLED_ROOT="$TEST_ROOT/disabled"
cp -a "$FIXTURE_ROOT/." "$DISABLED_ROOT/"
jq '.services[0].enabled = false' "$DISABLED_ROOT/registry/services.json" > "$DISABLED_ROOT/registry/services.tmp"
mv "$DISABLED_ROOT/registry/services.tmp" "$DISABLED_ROOT/registry/services.json"
disabled_backups="$(REGISTRY_ROOT="$DISABLED_ROOT/registry" REGISTRY_TRUSTED_ROOT="$DISABLED_ROOT" \
    bash -c 'source "$1/scripts/core/registry.sh"; registry_validate; registry_backup_services' _ "$REPO_DIR")"
[ -z "$disabled_backups" ] || fail "disabled service appeared in backup order"

restore_order="$(REGISTRY_ROOT="$REPO_DIR/registry" REGISTRY_TRUSTED_ROOT="$REPO_DIR" \
    bash -c 'source "$1/scripts/core/registry.sh"; registry_validate; registry_restore_plan | cut -f1 | paste -sd"," -' _ "$REPO_DIR")"
[ "$restore_order" = "redis,postgres,minio" ] || fail "unexpected restore phase order: $restore_order"

echo "Testing source-to-runtime mappings..."
while IFS=$'\t' read -r source destination; do
    [ -f "$REPO_DIR/$source" ] || fail "registered source is missing: $source"
    case "$destination" in
        scripts/services/*/adapter.sh|scripts/services/*/provision.sh|scripts/restore-*.sh|backup/backup-*.sh) ;;
        *) fail "unexpected runtime destination: $destination" ;;
    esac
done < <(REGISTRY_ROOT="$REPO_DIR/registry" REGISTRY_TRUSTED_ROOT="$REPO_DIR" \
    bash -c 'source "$1/scripts/core/registry.sh"; registry_validate; registry_sync_manifest' _ "$REPO_DIR")

grep -Fq 'scripts/projects/create-project.sh' "$REPO_DIR/scripts/deployment/sync-infra.sh" ||
    fail "sync does not map the refactored project CLI"
grep -Fq 'create-project.sh' "$REPO_DIR/scripts/deployment/sync-infra.sh" ||
    fail "sync does not preserve the public create-project runtime command"
grep -Fq 'scripts/backup/backup-all.sh' "$REPO_DIR/scripts/deployment/sync-infra.sh" ||
    fail "sync does not preserve the backup orchestrator runtime command"

INSTALLED_LAYOUT="$TEST_ROOT/installed-layout"
mkdir -p "$INSTALLED_LAYOUT/scripts/core" "$INSTALLED_LAYOUT/scripts/services" \
    "$INSTALLED_LAYOUT/backup" "$INSTALLED_LAYOUT/registry" "$INSTALLED_LAYOUT/stacks"
cp "$REPO_DIR/scripts/core/"*.sh "$INSTALLED_LAYOUT/scripts/core/"
cp "$REPO_DIR/scripts/projects/list-services.sh" "$INSTALLED_LAYOUT/scripts/list-services.sh"
cp "$REPO_DIR/registry/"*.json "$INSTALLED_LAYOUT/registry/"
cp "$REPO_DIR/stacks/"*.yml "$INSTALLED_LAYOUT/stacks/"
while IFS=$'\t' read -r source destination; do
    mkdir -p "$(dirname "$INSTALLED_LAYOUT/$destination")"
    cp "$REPO_DIR/$source" "$INSTALLED_LAYOUT/$destination"
done < <(REGISTRY_ROOT="$REPO_DIR/registry" REGISTRY_TRUSTED_ROOT="$REPO_DIR" \
    bash -c 'source "$1/scripts/core/registry.sh"; registry_validate; registry_sync_manifest' _ "$REPO_DIR")
output="$(INFRA_ROOT="$INSTALLED_LAYOUT" bash "$INSTALLED_LAYOUT/scripts/list-services.sh")"
assert_contains "$output" "postgres"
assert_contains "$output" "redis"
assert_contains "$output" "minio"

echo "Testing registry-driven backup behavior..."
REGISTRY_RUNTIME="$TEST_ROOT/registry-runtime"
mkdir -p "$REGISTRY_RUNTIME/scripts/core" "$REGISTRY_RUNTIME/scripts/services/mock-service" \
    "$REGISTRY_RUNTIME/backup" "$REGISTRY_RUNTIME/registry" "$REGISTRY_RUNTIME/stacks"
cp "$REPO_DIR/scripts/core/registry.sh" "$REGISTRY_RUNTIME/scripts/core/registry.sh"
cp "$FIXTURE_ROOT/registry/"*.json "$REGISTRY_RUNTIME/registry/"
cp "$FIXTURE_ROOT/stacks/"*.yml "$REGISTRY_RUNTIME/stacks/"
cp "$FIXTURE_ROOT/scripts/services/mock-service/adapter.sh" "$REGISTRY_RUNTIME/scripts/services/mock-service/adapter.sh"
cp "$FIXTURE_ROOT/scripts/services/mock-service/backup.sh" "$REGISTRY_RUNTIME/backup/backup-mock-service.sh"
cp "$FIXTURE_ROOT/scripts/services/mock-service/restore.sh" "$REGISTRY_RUNTIME/scripts/restore-mock-service.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REGISTRY_RUNTIME/backup/backup-infra.sh"
chmod 700 "$REGISTRY_RUNTIME/backup/"*.sh
output="$(INFRA_ROOT="$REGISTRY_RUNTIME" BACKUP_DIR="$REGISTRY_RUNTIME/backup" \
    bash "$REPO_DIR/scripts/backup/backup-all.sh")"
assert_contains "$output" "[SUCCESS] mock-service"

sed -i 's/service_backup_available() { return 0; }/service_backup_available() { return 1; }/' \
    "$REGISTRY_RUNTIME/scripts/services/mock-service/adapter.sh"
jq '.services[0].backup.required_when_enabled = true' "$REGISTRY_RUNTIME/registry/services.json" > "$REGISTRY_RUNTIME/registry/services.tmp"
mv "$REGISTRY_RUNTIME/registry/services.tmp" "$REGISTRY_RUNTIME/registry/services.json"
set +e
INFRA_ROOT="$REGISTRY_RUNTIME" BACKUP_DIR="$REGISTRY_RUNTIME/backup" \
    bash "$REPO_DIR/scripts/backup/backup-all.sh" > "$REGISTRY_RUNTIME/backup.out" 2>&1
required_failure_result=$?
set -e
[ "$required_failure_result" -ne 0 ] || fail "required unavailable backup service did not fail"
assert_contains "$(cat "$REGISTRY_RUNTIME/backup.out")" "enabled backup service is unavailable"

echo "Testing extensible and legacy project manifests..."
MANIFEST_ROOT="$TEST_ROOT/manifest-runtime"
mkdir -p "$MANIFEST_ROOT/projects/example"
printf 'PROJECT_NAME=example\n' > "$MANIFEST_ROOT/projects/example/.env"
printf '{"name":"example","status":"provisioned","services":{"postgres":true,"future-service":false}}\n' \
    > "$MANIFEST_ROOT/projects/example/project.json"
INFRA_ROOT="$MANIFEST_ROOT" bash -c '
    source "$1/scripts/core/common.sh"
    PROJECT=example
    init_project_paths "$PROJECT"
    require_managed_project
' _ "$REPO_DIR"

grep -Fq -- '--services' "$REPO_DIR/scripts/projects/orchestrator.sh" || fail "dynamic --services selection is missing"
for legacy_flag in --postgres --redis --minio --all; do
    grep -Fq -- "$legacy_flag" "$REPO_DIR/scripts/projects/orchestrator.sh" || fail "legacy flag is missing: $legacy_flag"
done
grep -Fq 'Registry is not installed' "$REPO_DIR/scripts/backup/backup-all.sh" || fail "legacy backup fallback is missing"

echo "Testing backup lock inheritance and contention..."
grep -Fq 'acquire_destructive_project_locks' "$REPO_DIR/scripts/projects/delete-project.sh" ||
    fail "delete-project does not use ordered destructive locks"
grep -Fq '/opt/infra/backup/backup-all.sh' "$REPO_DIR/scripts/projects/delete-project.sh" ||
    fail "backup-before-delete is missing"
for component_script in \
    services/postgres/backup.sh \
    services/redis/backup.sh \
    services/minio/backup.sh \
    backup/backup-infra.sh
do
    grep -Fq 'BACKUP_LOCK_HELD' "$REPO_DIR/scripts/$component_script" ||
        fail "$component_script cannot inherit the aggregate backup lock"
done
LOCK_BACKUP="$TEST_ROOT/lock-backup"
mkdir -p "$LOCK_BACKUP"
for component in postgres redis minio infra; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$LOCK_BACKUP/backup-$component.sh"
    chmod 700 "$LOCK_BACKUP/backup-$component.sh"
done
BACKUP_DIR="$LOCK_BACKUP" bash "$REPO_DIR/scripts/backup/backup-all.sh" >/dev/null
(
    exec 8>"$LOCK_BACKUP/backup.lock"
    flock -n 8
    BACKUP_LOCK_HELD=1 BACKUP_DIR="$LOCK_BACKUP" \
        bash "$REPO_DIR/scripts/backup/backup-all.sh" >/dev/null
)
(
    exec 8>"$LOCK_BACKUP/backup.lock"
    flock -n 8
    touch "$LOCK_BACKUP/ready"
    sleep 2
) &
LOCK_HOLDER=$!
while [ ! -f "$LOCK_BACKUP/ready" ]; do sleep 0.05; done
if BACKUP_DIR="$LOCK_BACKUP" bash "$REPO_DIR/scripts/backup/backup-all.sh" \
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
PATH="$MOCK_BIN:$PATH" bash "$REPO_DIR/scripts/setup/setup-backup.sh" --fresh >/dev/null
SKIP_RESULT=$?
set -e
[ "$SKIP_RESULT" -eq 10 ] || fail "skipped backup setup returned an unexpected status"
[ ! -e "$SKIP_BACKUP_ROOT/backup/.env" ] || fail "skipped backup setup created credentials"

FRESH_BACKUP_ROOT="$TEST_ROOT/fresh-backup"
MOCK_RESTIC_LOG="$TEST_ROOT/fresh-restic.log" \
MOCK_RESTIC_INITIALIZED="$TEST_ROOT/fresh-initialized" \
MOCK_RESTIC_MODE=fresh INFRA_ROOT="$FRESH_BACKUP_ROOT" INFRA_TEST_MODE=1 \
PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_DIR/scripts/setup/setup-backup.sh" --fresh <<EOF >/dev/null
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
    bash "$REPO_DIR/scripts/setup/setup-backup.sh" verify >/dev/null
after="$(sha256sum "$FRESH_BACKUP_ROOT/backup/.env" "$FRESH_BACKUP_ROOT/backup/.restic-password" "$FRESH_BACKUP_ROOT/backup/rclone.conf")"
[ "$before" = "$after" ] || fail "existing backup credentials were changed"

RESTORE_BACKUP_ROOT="$TEST_ROOT/restore-backup"
MOCK_RESTIC_LOG="$TEST_ROOT/restore-restic.log" \
MOCK_RESTIC_INITIALIZED="$TEST_ROOT/restore-initialized" \
MOCK_RESTIC_MODE=restore INFRA_ROOT="$RESTORE_BACKUP_ROOT" INFRA_TEST_MODE=1 \
PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_DIR/scripts/setup/setup-backup.sh" --restore <<EOF >/dev/null
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
