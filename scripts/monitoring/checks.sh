#!/usr/bin/env bash
# Check results are tab-separated: key, severity, current, expected.
emit_issue() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

check_host() {
    local cpu1 idle1 total1 cpu2 idle2 total2 usage available swap_total swap_free swap_used disk
    read -r _ cpu1 _ _ idle1 _ < /proc/stat
    total1="$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/stat)"
    sleep 1
    read -r _ cpu2 _ _ idle2 _ < /proc/stat
    total2="$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/stat)"
    if [ "$total2" -gt "$total1" ]; then
        usage=$((100 * ((total2-total1)-(idle2-idle1)) / (total2-total1)))
        [ "$usage" -le "${CPU_LIMIT:-90}" ] || emit_issue host.cpu warning "$usage%" "<= ${CPU_LIMIT:-90}%"
    fi
    available="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
    [ "$available" -ge "${RAM_MIN_MIB:-100}" ] || emit_issue host.ram critical "${available} MiB" ">= ${RAM_MIN_MIB:-100} MiB"
    swap_total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    swap_free="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"
    if [ "$swap_total" -gt 0 ]; then
        swap_used=$((100 * (swap_total-swap_free) / swap_total))
        [ "$swap_used" -le "${SWAP_LIMIT:-80}" ] || emit_issue host.swap warning "$swap_used%" "<= ${SWAP_LIMIT:-80}%"
    fi
    disk="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    [ "$disk" -le "${DISK_LIMIT:-85}" ] || emit_issue host.disk critical "$disk%" "<= ${DISK_LIMIT:-85}%"
}

check_tls() {
    local domain host port protocol endpoint output
    domain="$(sed -n 's/^INFRA_DOMAIN=//p' "$INFRA_ROOT/infrastructure.env" 2>/dev/null | head -n 1)"
    [ -n "$domain" ] || { emit_issue tls.config warning missing 'INFRA_DOMAIN configured'; return; }
    while IFS=$'\t' read -r host port protocol; do
        endpoint="$host.$domain"
        [ "$host" != gateway ] || endpoint="$domain"
        if [ "$protocol" = postgres ]; then
            output="$(timeout 12 openssl s_client -starttls postgres -connect "$endpoint:$port" -servername "$endpoint" </dev/null 2>/dev/null | openssl x509 -noout -checkend "$(( ${TLS_WARN_DAYS:-14} * 86400 ))" 2>/dev/null)" || output=''
        else
            output="$(timeout 12 openssl s_client -connect "$endpoint:$port" -servername "$endpoint" </dev/null 2>/dev/null | openssl x509 -noout -checkend "$(( ${TLS_WARN_DAYS:-14} * 86400 ))" 2>/dev/null)" || output=''
        fi
        [ "$output" = 'Certificate will not expire' ] || emit_issue "tls.$host" warning 'expired, expiring or unreachable' "valid > ${TLS_WARN_DAYS:-14} days"
    done < <(
        jq -r '.stacks[] | select(.enabled == true) | if .id == "database" then "postgres\t6433\tpostgres" elif .id == "cache" then "redis\t6380\ttls" elif .id == "storage" then "minio\t443\thttps" else empty end' "$INFRA_ROOT/registry/stacks.json"
        if [ "${MONITOR_ROOT_TLS:-0}" = 1 ] &&
           jq -e '.stacks[] | select(.id == "gateway" and .enabled == true)' "$INFRA_ROOT/registry/stacks.json" >/dev/null; then
            printf 'gateway\t443\thttps\n'
        fi
    )
}

check_containers() {
    local stack container state health service
    [ -s "$INFRA_ROOT/registry/stacks.json" ] || { emit_issue registry critical missing 'registry available'; return; }
    while IFS= read -r container; do
        [ -n "$container" ] || continue
        state="$(timeout 8 docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)" || state=missing
        [ "$state" = running ] || { emit_issue "container.$container" critical "$state" running; continue; }
        health="$(timeout 8 docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null)" || health=unknown
        [ "$health" != unhealthy ] || emit_issue "container.$container" critical unhealthy healthy
    done < <(jq -r '.stacks[] | select(.enabled == true) | .containers[]' "$INFRA_ROOT/registry/stacks.json" | sort -u)
    if [ -s "$INFRA_ROOT/registry/services.json" ] && [ -s "$INFRA_ROOT/scripts/core/registry.sh" ]; then
        REGISTRY_ROOT="$INFRA_ROOT/registry" REGISTRY_TRUSTED_ROOT="$INFRA_ROOT"
        export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT
        source "$INFRA_ROOT/scripts/core/registry.sh"
        while IFS= read -r service; do
            [ -n "$service" ] || continue
            if ! timeout 10 bash -c 'source "$1"; registry_run_service_hook "$2" health' _ "$INFRA_ROOT/scripts/core/registry.sh" "$service" >/dev/null 2>&1; then
                emit_issue "service.$service" critical failed 'health hook succeeds'
            fi
        done < <(jq -r '.services[] | select(.enabled == true and (.capabilities | index("health"))) | .id' "$INFRA_ROOT/registry/services.json")
    fi
    if [ -f "$INFRA_ROOT/deployment.env" ] && grep -q '^DEPLOYMENT_MODE=gitops$' "$INFRA_ROOT/deployment.env"; then
        state="$(timeout 8 docker inspect -f '{{.State.Status}}' dockhand 2>/dev/null)" || state=missing
        [ "$state" = running ] || emit_issue container.dockhand critical "$state" running
    fi
}

check_backup_sync() {
    local file="$INFRA_ROOT/state/backup-status" result success age state updated
    if [ -s "$INFRA_ROOT/backup/.env" ]; then
        # A running aggregate backup is not a failed backup.
        backup_running=false
        if [ -f "$INFRA_ROOT/backup/backup.lock" ]; then
            exec 8>"$INFRA_ROOT/backup/backup.lock"
            if ! flock -n 8; then backup_running=true; fi
            flock -u 8 2>/dev/null || true
            exec 8>&-
        fi
        if $backup_running; then :
        elif [ ! -s "$file" ]; then emit_issue backup.status warning missing 'complete backup within 26h'; else
            result="$(sed -n 's/^result=//p' "$file")"
            success="$(sed -n 's/^last_success=//p' "$file")"
            [ "$result" != failed ] || emit_issue backup.result critical failed success
            age="$(date -u -d "$success" +%s 2>/dev/null)" || age=0
            [ $(( $(date -u +%s) - age )) -le 93600 ] || emit_issue backup.age critical overdue 'complete backup within 26h'
        fi
    fi
    if [ -f "$INFRA_ROOT/deployment.env" ] && grep -q '^DEPLOYMENT_MODE=gitops$' "$INFRA_ROOT/deployment.env"; then
        file="$INFRA_ROOT/state/sync-status"
        if [ ! -s "$file" ]; then emit_issue sync.status warning missing 'recent sync status'; else
            state="$(sed -n 's/^status=//p' "$file")"
            updated="$(sed -n 's/^updated=//p' "$file")"
            age="$(date -u -d "$updated" +%s 2>/dev/null)" || age=0
            case "$state" in failed|recovery-required) emit_issue sync.status critical "$state" healthy ;; postponed)
                [ $(( $(date -u +%s) - age )) -le 3600 ] || emit_issue sync.status warning postponed 'retry within 1h' ;;
            esac
            [ $(( $(date -u +%s) - age )) -le 3600 ] || emit_issue sync.stale warning stale 'updated within 1h'
        fi
    fi
}
