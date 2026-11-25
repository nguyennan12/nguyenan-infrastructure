#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_ROOT="${REGISTRY_ROOT:-$REPO_DIR/registry}"
REGISTRY_TRUSTED_ROOT="${REGISTRY_TRUSTED_ROOT:-$REPO_DIR}"
export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT

source "$SCRIPT_DIR/../core/registry.sh"
registry_validate

echo "Infrastructure registry validation passed."
echo "Stack order: $(registry_stack_order | tr '\n' ' ')"
echo "Backup order: $(registry_backup_services | tr '\n' ' ')"
