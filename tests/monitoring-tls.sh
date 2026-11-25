#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/infra/registry" "$TEST_ROOT/bin"
cp "$REPO/registry/stacks.json" "$TEST_ROOT/infra/registry/stacks.json"
printf 'INFRA_DOMAIN=example.test\n' > "$TEST_ROOT/infra/infrastructure.env"
printf '#!/usr/bin/env bash\nif [ "$1" = s_client ]; then printf "%%s\\n" "$*" >> "$TLS_PROBE_LOG"; else echo "Certificate will not expire"; fi\n' > "$TEST_ROOT/bin/openssl"
chmod 700 "$TEST_ROOT/bin/openssl"
export INFRA_ROOT="$TEST_ROOT/infra" TLS_PROBE_LOG="$TEST_ROOT/probes.log"
export PATH="$TEST_ROOT/bin:$PATH"
source "$REPO/scripts/monitoring/checks.sh"
check_tls > "$TEST_ROOT/issues"
[ ! -s "$TEST_ROOT/issues" ]
[ "$(wc -l < "$TLS_PROBE_LOG")" -eq 3 ]
grep -Fq -- '-starttls postgres -connect postgres.example.test:6433 -servername postgres.example.test' "$TLS_PROBE_LOG"
grep -Fq -- '-connect redis.example.test:6380 -servername redis.example.test' "$TLS_PROBE_LOG"
grep -Fq -- '-connect minio.example.test:443 -servername minio.example.test' "$TLS_PROBE_LOG"
if grep -Fq -- '-connect example.test:443' "$TLS_PROBE_LOG"; then
    echo 'Unexpected root-domain TLS probe.' >&2; exit 1
fi
MONITOR_ROOT_TLS=1 check_tls > "$TEST_ROOT/issues"
[ "$(wc -l < "$TLS_PROBE_LOG")" -eq 7 ]
grep -Fq -- '-connect example.test:443 -servername example.test' "$TLS_PROBE_LOG"
echo 'TLS endpoint selection checks passed.'
