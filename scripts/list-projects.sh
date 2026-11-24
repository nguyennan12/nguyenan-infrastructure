#!/usr/bin/env bash

set -euo pipefail

PROJECTS_DIR="/opt/infra/projects"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

echo "===== Infrastructure Projects ====="
echo

printf "%-20s %-25s %-18s %-15s\n" \
    "PROJECT" "DATABASE" "BUCKET" "STATUS"

printf '%s\n' \
    "--------------------------------------------------------------------------"

COUNT=0

if [ -d "$PROJECTS_DIR" ]; then
    for dir in "$PROJECTS_DIR"/*; do
        [ -d "$dir" ] || continue

        PROJECT="$(basename "$dir")"

        if [ -f "$dir/.provisioned" ]; then
            STATUS="Provisioned"
        else
            STATUS="Incomplete"
        fi

        printf "%-20s %-25s %-18s %-15s\n" \
            "$PROJECT" \
            "${PROJECT}_db" \
            "$PROJECT" \
            "$STATUS"

        COUNT=$((COUNT + 1))
    done
fi

echo
echo "Total managed projects: $COUNT"