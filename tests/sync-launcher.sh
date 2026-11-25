#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
git init -q --bare "$TEST_ROOT/origin.git"
git clone -q "$TEST_ROOT/origin.git" "$TEST_ROOT/source"
git -C "$TEST_ROOT/source" config user.email sync-test@example.invalid
git -C "$TEST_ROOT/source" config user.name SyncTest
mkdir -p "$TEST_ROOT/source/scripts/deployment"
printf '#!/usr/bin/env bash\nprintf "first\\n" >> "$INFRA_ROOT/worker-runs"\nprintf "%%s\\n" "$INFRA_SYNC_TARGET_COMMIT" > "$INFRA_ROOT/state/last-sync-commit"\n' > "$TEST_ROOT/source/scripts/deployment/sync-infra.sh"
git -C "$TEST_ROOT/source" add .
git -C "$TEST_ROOT/source" commit -qm first
git -C "$TEST_ROOT/source" branch -M production
git -C "$TEST_ROOT/source" push -q origin production
git clone -q "$TEST_ROOT/origin.git" "$TEST_ROOT/repository"
mkdir -p "$TEST_ROOT/infra/state"

run_launcher() {
    INFRA_TEST_MODE=1 INFRA_ROOT="$TEST_ROOT/infra" REPO_DIR="$TEST_ROOT/repository" \
        bash "$ROOT/scripts/deployment/sync-launcher.sh"
}
run_launcher >/dev/null
[ "$(cat "$TEST_ROOT/infra/worker-runs")" = first ]
run_launcher >/dev/null
[ "$(wc -l < "$TEST_ROOT/infra/worker-runs")" -eq 1 ]

printf '#!/usr/bin/env bash\nprintf "second\\n" >> "$INFRA_ROOT/worker-runs"\nprintf "%%s\\n" "$INFRA_SYNC_TARGET_COMMIT" > "$INFRA_ROOT/state/last-sync-commit"\n' > "$TEST_ROOT/source/scripts/deployment/sync-infra.sh"
git -C "$TEST_ROOT/source" add .
git -C "$TEST_ROOT/source" commit -qm second
git -C "$TEST_ROOT/source" push -q origin production
run_launcher >/dev/null
[ "$(tail -n 1 "$TEST_ROOT/infra/worker-runs")" = second ]
[ "$(find "$TEST_ROOT/infra/state" -name '.sync-worker.*' | wc -l)" -eq 0 ]

printf '#!/usr/bin/env bash\nif then\n' > "$TEST_ROOT/source/scripts/deployment/sync-infra.sh"
git -C "$TEST_ROOT/source" add .
git -C "$TEST_ROOT/source" commit -qm invalid
git -C "$TEST_ROOT/source" push -q origin production
if run_launcher > "$TEST_ROOT/invalid.log" 2>&1; then
    echo 'Invalid worker syntax was accepted.' >&2; exit 1
fi
[ "$(wc -l < "$TEST_ROOT/infra/worker-runs")" -eq 2 ]
[ "$(find "$TEST_ROOT/infra/state" -name '.sync-worker.*' | wc -l)" -eq 0 ]
echo 'Sync launcher integration checks passed.'
