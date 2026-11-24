#!/usr/bin/env bash

set -euo pipefail

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