#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
source "$SCRIPTS_ROOT/core/common.sh"
source "$SCRIPTS_ROOT/core/registry.sh"

registry_validate

printf '%-12s %-12s %-11s %-9s %-10s %-11s %-9s\n' \
    SERVICE STACK REGISTERED ENABLED AVAILABLE DEPLOYED HEALTH
printf '%s\n' '--------------------------------------------------------------------------------'

while IFS= read -r service; do
    stack="$(registry_service_get "$service" | jq -r '.stack')"
    enabled="$(registry_service_get "$service" | jq -r '.enabled')"
    deployed=yes
    while IFS= read -r container; do
        if ! command -v docker >/dev/null ||
           ! docker container inspect "$container" >/dev/null 2>&1; then
            deployed=no
            break
        fi
    done < <(registry_stack_get "$stack" | jq -r '.containers[]')

    if registry_service_available "$service"; then available=yes; else available=no; fi

    if registry_service_health "$service" >/dev/null 2>&1; then
        health=healthy
    elif [ "$deployed" = yes ]; then
        health=unhealthy
    else
        health=unknown
    fi

    printf '%-12s %-12s %-11s %-9s %-10s %-11s %-9s\n' \
        "$service" "$stack" yes "$enabled" "$available" "$deployed" "$health"
done < <(registry_list_services)
