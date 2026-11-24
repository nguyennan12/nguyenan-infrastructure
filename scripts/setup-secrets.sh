#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
REPO_DIR_EXPLICIT="${REPO_DIR:-}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SECRETS_DIR="$INFRA_ROOT/secrets"

source "$SCRIPT_DIR/lib/common.sh"

if [ -z "$REPO_DIR_EXPLICIT" ]; then
    CONFIGURED_REPO="$(read_config_value "$INFRA_ROOT/deployment.env" REPOSITORY_DIR || true)"
    [ -z "$CONFIGURED_REPO" ] || REPO_DIR="$CONFIGURED_REPO"
fi

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != "1" ]; then
    echo "Please run with sudo."
    exit 1
fi

NON_INTERACTIVE=false
[ "${1:-}" = "--non-interactive" ] && NON_INTERACTIVE=true

required_variables() {
    grep -rhoE '\$\{[A-Z][A-Z0-9_]*([:?+-][^}]*)?\}' "$REPO_DIR/stacks"/*.yml |
        sed -E 's/^\$\{//; s/[:?+\-].*$//; s/\}$//' |
        sort -u
}

EXPECTED_VARS="ACME_EMAIL INFRA_DOMAIN MINIO_ROOT_PASSWORD MINIO_ROOT_USER PGBOUNCER_AUTH_PASSWORD POSTGRES_PASSWORD REDIS_PASSWORD"
DISCOVERED_VARS="$(required_variables | tr '\n' ' ' | sed 's/ $//')"

if [ "$DISCOVERED_VARS" != "$EXPECTED_VARS" ]; then
    echo "Compose variable set changed. Review setup-secrets.sh before continuing." >&2
    echo "Expected names: $EXPECTED_VARS" >&2
    echo "Discovered names: $DISCOVERED_VARS" >&2
    exit 1
fi

install -d -m 700 "$SECRETS_DIR"
if [ "$EUID" -eq 0 ]; then
    chown root:root "$SECRETS_DIR"
fi

secret_file_for() {
    case "$1" in
        POSTGRES_PASSWORD|PGBOUNCER_AUTH_PASSWORD) echo "$SECRETS_DIR/database.env" ;;
        REDIS_PASSWORD) echo "$SECRETS_DIR/cache.env" ;;
        MINIO_ROOT_USER|MINIO_ROOT_PASSWORD) echo "$SECRETS_DIR/storage.env" ;;
        ACME_EMAIL) echo "$SECRETS_DIR/gateway.env" ;;
        *) return 1 ;;
    esac
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

if [ -z "${ACME_EMAIL:-}" ] && ! grep -qE '^ACME_EMAIL=' "$SECRETS_DIR/gateway.env" 2>/dev/null; then
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

ensure_value ACME_EMAIL
ensure_value POSTGRES_PASSWORD
ensure_value PGBOUNCER_AUTH_PASSWORD
ensure_value REDIS_PASSWORD
ensure_value MINIO_ROOT_USER infra_admin
ensure_value MINIO_ROOT_PASSWORD

ACME_EMAIL_VALUE="$(sed -n 's/^ACME_EMAIL=//p' "$SECRETS_DIR/gateway.env")"
if [[ ! "$ACME_EMAIL_VALUE" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Configured ACME_EMAIL is invalid." >&2
    exit 1
fi
unset ACME_EMAIL_VALUE

REDIS_PASSWORD_VALUE="$(sed -n 's/^REDIS_PASSWORD=//p' "$SECRETS_DIR/cache.env")"
REDIS_BACKUP_FILE="$INFRA_ROOT/backup/.redis-password"
install -d -m 700 "$INFRA_ROOT/backup"

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
