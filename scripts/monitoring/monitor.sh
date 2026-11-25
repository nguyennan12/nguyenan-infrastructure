#!/usr/bin/env bash
set -euo pipefail
umask 077
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
MONITOR_DIR="$INFRA_ROOT/monitoring"
STATE_DIR="$INFRA_ROOT/state/monitoring"
WEBHOOK_FILE="$MONITOR_DIR/.discord-webhook"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/checks.sh"
source "$SCRIPT_DIR/notify.sh"

usage() { echo 'Usage: monitor.sh [--check|--status|--test-notification|--dry-run|--help]'; }
case "${1:-}" in --help|-h) usage; exit 0 ;; --check|--status|--test-notification|--dry-run|'') ;; *) usage >&2; exit 2 ;; esac
if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != 1 ]; then echo 'Please run as root.' >&2; exit 1; fi
install -d -m 700 "$STATE_DIR"
if [ "${1:-}" = --status ]; then
    for file in "$STATE_DIR"/*.state; do [ ! -f "$file" ] || jq -r '[.check,.active,.failures,.recoveries,.last_sent] | @tsv' "$file"; done
    exit 0
fi
if [ "${1:-}" = --test-notification ]; then
    send_notification warning monitoring.test 'Simulated warning' 'Test only'
    send_notification recovery monitoring.test 'Simulated recovery' 'Test only'
    exit 0
fi
exec 9>"$STATE_DIR/monitor.lock"
if ! flock -n 9; then echo 'Monitoring run already active; skipped.'; exit 0; fi
ISSUES="$(mktemp "$STATE_DIR/.issues.XXXXXX")"
trap 'rm -f -- "$ISSUES"' EXIT
check_host >> "$ISSUES"
check_containers >> "$ISSUES"
check_backup_sync >> "$ISSUES"
if [ ! -f "$STATE_DIR/tls-last-check" ] || [ $(( $(date -u +%s) - $(cat "$STATE_DIR/tls-last-check") )) -ge 86400 ]; then
    tls_issues="$(mktemp "$STATE_DIR/.tls.XXXXXX")"
    check_tls > "$tls_issues"
    cat "$tls_issues" >> "$ISSUES"
    if [ "${1:-}" != --check ] && [ "${1:-}" != --dry-run ]; then
        mv -fT "$tls_issues" "$STATE_DIR/tls-issues"
        date -u +%s > "$STATE_DIR/tls-last-check.tmp"
        mv -fT "$STATE_DIR/tls-last-check.tmp" "$STATE_DIR/tls-last-check"
    else
        rm -f -- "$tls_issues"
    fi
elif [ -f "$STATE_DIR/tls-issues" ]; then
    cat "$STATE_DIR/tls-issues" >> "$ISSUES"
fi
if [ "${1:-}" = --check ] || [ "${1:-}" = --dry-run ]; then
    if [ -s "$ISSUES" ]; then cat "$ISSUES"; else echo 'All evaluated checks healthy.'; fi
    exit 0
fi
if [ ! -s "$WEBHOOK_FILE" ]; then echo 'Monitoring webhook missing; alerts were not delivered.' >&2; exit 1; fi

# A state file is written only after notification success. Failed deliveries
# are retried next run; two healthy evaluations are needed for recovery.
while IFS=$'\t' read -r key severity detail threshold; do
    [ -n "$key" ] || continue
    [[ "$key" =~ ^[a-z0-9.-]+$ ]] || continue
    file="$STATE_DIR/$key.state"
    failures=0; active=false; last_sent=0
    if [ -f "$file" ]; then
        failures="$(jq -r '.failures' "$file")"
        active="$(jq -r '.active' "$file")"
        last_sent="$(jq -r '.last_sent' "$file")"
    fi
    failures=$((failures+1))
    deliver=false
    required=2; [ "$key" != host.cpu ] || required=3
    [ "$active" != false ] || [ "$failures" -lt "$required" ] || deliver=true
    [ "$active" != true ] || [ $(( $(date -u +%s) - last_sent )) -lt 21600 ] || deliver=true
    if [ "$deliver" = true ] && send_notification "$severity" "$key" "$detail" "$threshold"; then
        active=true; last_sent="$(date -u +%s)"
    fi
    tmp="$(mktemp "$STATE_DIR/.incident.XXXXXX")"
    jq -nc --arg check "$key" --arg severity "$severity" --arg detail "$detail" \
        --argjson failures "$failures" --argjson last_sent "$last_sent" --argjson active "$active" \
        '{check:$check,severity:$severity,detail:$detail,failures:$failures,recoveries:0,active:$active,last_sent:$last_sent}' > "$tmp"
    chmod 600 "$tmp"; mv -fT "$tmp" "$file"
done < "$ISSUES"
for file in "$STATE_DIR"/*.state; do
    [ -f "$file" ] || continue
    key="$(jq -r '.check' "$file")"
    if [[ "$key" == backup.* ]] && "${backup_running:-false}"; then continue; fi
    if awk -F '\t' -v key="$key" '$1==key {found=1} END {exit !found}' "$ISSUES"; then continue; fi
    active="$(jq -r '.active' "$file")"
    recoveries=$(( $(jq -r '.recoveries' "$file") + 1 ))
    if [ "$active" = true ] && [ "$recoveries" -ge 2 ]; then
        if send_notification recovery "$key" healthy 'condition cleared'; then active=false; fi
    fi
    tmp="$(mktemp "$STATE_DIR/.incident.XXXXXX")"
    jq --argjson active "$active" --argjson recoveries "$recoveries" \
        '.active=$active | .recoveries=$recoveries | .failures=0' "$file" > "$tmp"
    chmod 600 "$tmp"; mv -fT "$tmp" "$file"
done
