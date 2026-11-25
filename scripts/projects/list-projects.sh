#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    REGISTRY_CORE="$SCRIPT_DIR/orchestrator.sh"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
    REGISTRY_CORE="$SCRIPT_DIR/project-services.sh"
fi
REGISTRY_DIR_CANDIDATE="$(cd "$SCRIPTS_ROOT/.." && pwd)/registry"
if [ -f "$REGISTRY_CORE" ]; then
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then exec bash "$REGISTRY_CORE" list "$@"; fi
    if [ ! -s "$REGISTRY_DIR_CANDIDATE/stacks.json" ] || [ ! -s "$REGISTRY_DIR_CANDIDATE/services.json" ]; then
        echo "Installed service registry is missing; refusing legacy fallback." >&2
        exit 1
    fi
    exec bash "$REGISTRY_CORE" list "$@"
fi

PROJECTS_DIR="/opt/infra/projects"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

command -v jq >/dev/null

service_status() {
    local manifest="$1"
    local service="$2"

    if jq -e \
        --arg service "$service" \
        '.services[$service] == true' \
        "$manifest" >/dev/null; then

        echo "YES"
    else
        echo "-"
    fi
}

echo "===== Infrastructure Projects ====="
echo

printf "%-20s %-12s %-10s %-10s %-15s\n" \
    "PROJECT" "POSTGRESQL" "REDIS" "MINIO" "STATUS"

printf '%s\n' \
    "-----------------------------------------------------------------------"

COUNT=0

if [ -d "$PROJECTS_DIR" ]; then
    for dir in "$PROJECTS_DIR"/*; do
        [ -d "$dir" ] || continue

        PROJECT="$(basename "$dir")"
        MANIFEST="$dir/project.json"

        if [ -f "$MANIFEST" ]; then

            POSTGRES="$(service_status "$MANIFEST" postgres)"
            REDIS="$(service_status "$MANIFEST" redis)"
            MINIO="$(service_status "$MANIFEST" minio)"

            STATUS="$(jq -r '.status // "unknown"' "$MANIFEST")"

        elif [ -f "$dir/.provisioned" ]; then

            POSTGRES="YES"
            REDIS="YES"
            MINIO="YES"
            STATUS="Legacy"

        else

            POSTGRES="?"
            REDIS="?"
            MINIO="?"
            STATUS="Incomplete"

        fi

        printf "%-20s %-12s %-10s %-10s %-15s\n" \
            "$PROJECT" \
            "$POSTGRES" \
            "$REDIS" \
            "$MINIO" \
            "$STATUS"

        COUNT=$((COUNT + 1))
    done
fi

echo
echo "Total managed projects: $COUNT"
