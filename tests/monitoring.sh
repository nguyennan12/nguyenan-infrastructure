#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/infra/monitoring" "$TEST_ROOT/infra/state/monitoring" "$TEST_ROOT/infra/registry" "$TEST_ROOT/bin"
printf '%s\n' 'https://discord.com/api/webhooks/123/temporary-test-token' > "$TEST_ROOT/infra/monitoring/.discord-webhook"
chmod 600 "$TEST_ROOT/infra/monitoring/.discord-webhook"
printf '{"stacks":[]}' > "$TEST_ROOT/infra/registry/stacks.json"
date -u +%s > "$TEST_ROOT/infra/state/monitoring/tls-last-check"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "sent\\n" >> "$MOCK_SENT_LOG"\nprintf 204\n' > "$TEST_ROOT/bin/curl"
chmod 700 "$TEST_ROOT/bin/curl"
run_monitor() {
    PATH="$TEST_ROOT/bin:$PATH" MOCK_SENT_LOG="$TEST_ROOT/sent.log" INFRA_ROOT="$TEST_ROOT/infra" \
        INFRA_TEST_MODE=1 RAM_MIN_MIB=999999999 CPU_LIMIT=100 SWAP_LIMIT=100 DISK_LIMIT=100 \
        bash "$REPO/scripts/monitoring/monitor.sh" "$@"
}
run_monitor --check | grep -q host.ram
run_monitor
[ ! -f "$TEST_ROOT/sent.log" ]
run_monitor
[ "$(wc -l < "$TEST_ROOT/sent.log")" -eq 1 ]
run_monitor
[ "$(wc -l < "$TEST_ROOT/sent.log")" -eq 1 ]
run_healthy() {
    PATH="$TEST_ROOT/bin:$PATH" MOCK_SENT_LOG="$TEST_ROOT/sent.log" INFRA_ROOT="$TEST_ROOT/infra" \
        INFRA_TEST_MODE=1 RAM_MIN_MIB=0 CPU_LIMIT=100 SWAP_LIMIT=100 DISK_LIMIT=100 \
        bash "$REPO/scripts/monitoring/monitor.sh"
}
run_healthy
run_healthy
[ "$(wc -l < "$TEST_ROOT/sent.log")" -eq 2 ]
[ -s "$TEST_ROOT/infra/monitoring/.discord-webhook" ]
echo 'Monitoring deduplication and recovery checks passed.'
