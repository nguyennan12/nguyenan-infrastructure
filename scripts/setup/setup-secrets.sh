#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
REPO_DIR_EXPLICIT="${REPO_DIR:-}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPTS_ROOT/.." && pwd)}"
SECRETS_DIR="$INFRA_ROOT/secrets"

source "$SCRIPTS_ROOT/core/common.sh"

if [ -z "$REPO_DIR_EXPLICIT" ]; then
    CONFIGURED_REPO="$(read_config_value "$INFRA_ROOT/deployment.env" REPOSITORY_DIR || true)"
    [ -z "$CONFIGURED_REPO" ] || REPO_DIR="$CONFIGURED_REPO"
fi

REGISTRY_ROOT="$REPO_DIR/registry"
REGISTRY_TRUSTED_ROOT="$REPO_DIR"
export REGISTRY_ROOT REGISTRY_TRUSTED_ROOT
source "$SCRIPTS_ROOT/core/registry.sh"
registry_validate

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != "1" ]; then
    echo "Please run with sudo."
    exit 1
fi

NON_INTERACTIVE=false
[ "${1:-}" = "--non-interactive" ] && NON_INTERACTIVE=true

required_variables() {
    local stack compose_file
    while IFS= read -r stack; do
        compose_file="$(registry_stack_get "$stack" | jq -r '.compose_file')"
        grep -hoE '\$\{[A-Z][A-Z0-9_]*([:?+-][^}]*)?\}' "$REPO_DIR/$compose_file" || true
    done < <(jq -r '.stacks[] | select(.enabled == true) | .id' "$STACK_REGISTRY" | sort) |
        sed -E 's/^\$\{//; s/[:?+\-].*$//; s/\}$//' |
        sort -u
}

EXPECTED_VARS="$(registry_required_environment | tr '\n' ' ' | sed 's/ $//')"
DISCOVERED_VARS="$(required_variables | tr '\n' ' ' | sed 's/ $//')"

if [ "$DISCOVERED_VARS" != "$EXPECTED_VARS" ]; then
    echo "Compose variable set changed. Review setup-secrets.sh before continuing." >&2
    echo "Expected names: $EXPECTED_VARS" >&2
    echo "Discovered names: $DISCOVERED_VARS" >&2
    exit 1
fi

if [ "${INFRA_TEST_MODE:-0}" = "1" ]; then
    mkdir -p "$SECRETS_DIR"
else
    install -d -m 700 "$SECRETS_DIR"
fi
if [ "$EUID" -eq 0 ]; then
    chown root:root "$SECRETS_DIR"
fi

secret_file_for() {
    local result
    result="$(jq -r --arg name "$1" \
        '[.stacks[] | select(any(.secrets[]?; .name == $name)) | .secret_file] | unique | .[]' \
        "$STACK_REGISTRY")"
    [ "$(wc -l <<< "$result")" -eq 1 ] && [ -n "$result" ] || return 1
    printf '%s/%s\n' "$SECRETS_DIR" "$result"
}

generate_password() {
    openssl rand -hex 24
}

ensure_value() {
    local key="$1"
    local default_value="${2:-}"
    local file
    local supplied=""

    file="$(secret_file_for "$key")"
    touch "$file"
    chmod 600 "$file"
    [ "$EUID" -ne 0 ] || chown root:root "$file"

    if grep -qE "^${key}=" "$file"; then
        return 0
    fi

    supplied="${!key:-}"
    if [ -z "$supplied" ]; then
        supplied="$default_value"
    fi
    if [ -z "$supplied" ]; then
        supplied="$(generate_password)"
    fi

    if [[ ! "$supplied" =~ ^[A-Za-z0-9._@%+=:-]+$ ]]; then
        echo "Explicit $key contains unsupported characters; use a single-line dotenv-safe value." >&2
        exit 1
    fi

    printf '%s=%s\n' "$key" "$supplied" >> "$file"
}

ACME_SECRET_FILE="$(secret_file_for ACME_EMAIL)"
if [ -z "${ACME_EMAIL:-}" ] && ! grep -qE '^ACME_EMAIL=' "$ACME_SECRET_FILE" 2>/dev/null; then
    if $NON_INTERACTIVE; then
        echo "ACME_EMAIL must be supplied for non-interactive setup." >&2
        exit 1
    fi
    read -r -p "Let's Encrypt email: " ACME_EMAIL
    if [[ ! "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        echo "Invalid email address." >&2
        exit 1
    fi
    export ACME_EMAIL
fi

while IFS=$'\t' read -r _stack _file key generator default_value; do
    case "$generator" in
        password|prompt-email) ensure_value "$key" ;;
        literal) ensure_value "$key" "$default_value" ;;
        *) echo "Unsupported secret generator for $key: $generator" >&2; exit 1 ;;
    esac
done < <(registry_secret_definitions)

ACME_EMAIL_VALUE="$(sed -n 's/^ACME_EMAIL=//p' "$ACME_SECRET_FILE")"
if [[ ! "$ACME_EMAIL_VALUE" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Configured ACME_EMAIL is invalid." >&2
    exit 1
fi
unset ACME_EMAIL_VALUE

REDIS_PASSWORD_FILE="$(secret_file_for REDIS_PASSWORD)"
REDIS_PASSWORD_VALUE="$(sed -n 's/^REDIS_PASSWORD=//p' "$REDIS_PASSWORD_FILE")"
REDIS_BACKUP_FILE="$INFRA_ROOT/backup/.redis-password"
if [ "${INFRA_TEST_MODE:-0}" = "1" ]; then
    mkdir -p "$INFRA_ROOT/backup"
else
    install -d -m 700 "$INFRA_ROOT/backup"
fi

if [ -e "$REDIS_BACKUP_FILE" ]; then
    if [ "$(cat "$REDIS_BACKUP_FILE")" != "$REDIS_PASSWORD_VALUE" ]; then
        echo "Existing Redis backup credential does not match cache.env; refusing to rotate either value." >&2
        exit 1
    fi
else
    printf '%s\n' "$REDIS_PASSWORD_VALUE" > "$REDIS_BACKUP_FILE"
    chmod 600 "$REDIS_BACKUP_FILE"
    [ "$EUID" -ne 0 ] || chown root:root "$REDIS_BACKUP_FILE"
fi

echo "Stack secret files initialized without displaying credentials."
