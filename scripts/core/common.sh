#!/usr/bin/env bash

INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
PROJECTS_DIR="${PROJECTS_DIR:-$INFRA_ROOT/projects}"
INFRA_CONFIG_FILE="${INFRA_CONFIG_FILE:-$INFRA_ROOT/infrastructure.env}"
DEPLOYMENT_CONFIG_FILE="${DEPLOYMENT_CONFIG_FILE:-$INFRA_ROOT/deployment.env}"

read_config_value() {
    local file="$1"
    local key="$2"
    local value=""
    local line

    test -f "$file" || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^(export[[:space:]]+)?${key}=(.*)$ ]]; then
            value="${BASH_REMATCH[2]}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            printf '%s\n' "$value"
            return 0
        fi
    done < "$file"

    return 1
}

load_deployment_config() {
    if [ ! -f "$DEPLOYMENT_CONFIG_FILE" ]; then
        echo "Deployment configuration not found: $DEPLOYMENT_CONFIG_FILE" >&2
        echo "Existing GitOps installations remain valid, but new deployment commands require an explicit mode." >&2
        return 1
    fi

    DEPLOYMENT_MODE="$(read_config_value "$DEPLOYMENT_CONFIG_FILE" DEPLOYMENT_MODE || true)"

    case "$DEPLOYMENT_MODE" in
        standalone|gitops) ;;
        *)
            echo "Invalid DEPLOYMENT_MODE in $DEPLOYMENT_CONFIG_FILE" >&2
            return 1
            ;;
    esac

    export DEPLOYMENT_MODE
}

validate_domain() {
    local domain="$1"

    if [ -z "$domain" ] || [[ "$domain" =~ ://|/|: ]] ||
       [ "${#domain}" -gt 253 ] ||
       [[ ! "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo "Invalid infrastructure domain: $domain" >&2
        return 1
    fi
}

load_infra_config() {
    if [ -n "${INFRA_DOMAIN:-}" ] && [ -n "${POSTGRES_HOST:-}" ] && [ -n "${REDIS_HOST:-}" ] && [ -n "${MINIO_HOST:-}" ]; then
        return 0
    fi

    if [ ! -f "$INFRA_CONFIG_FILE" ]; then
        echo "Configuration file not found: $INFRA_CONFIG_FILE" >&2
        echo "Please create $INFRA_CONFIG_FILE with INFRA_DOMAIN=<your-domain>" >&2
        exit 1
    fi

    local domain=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading and trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^INFRA_DOMAIN=(.*)$ ]]; then
            domain="${BASH_REMATCH[1]}"
            # Strip inline comment
            domain="${domain%%#*}"
            # Trim leading and trailing whitespace before removing quotes
            domain="${domain#"${domain%%[![:space:]]*}"}"
            domain="${domain%"${domain##*[![:space:]]}"}"
            # Strip quotes
            domain="${domain%\"}"
            domain="${domain#\"}"
            domain="${domain%\'}"
            domain="${domain#\'}"
            # Trim whitespace again if needed
            domain="${domain#"${domain%%[![:space:]]*}"}"
            domain="${domain%"${domain##*[![:space:]]}"}"
            break
        fi
    done < "$INFRA_CONFIG_FILE"

    if [ -z "$domain" ]; then
        echo "Error: INFRA_DOMAIN is missing or empty in $INFRA_CONFIG_FILE" >&2
        exit 1
    fi

    if ! validate_domain "$domain"; then
        exit 1
    fi

    export INFRA_DOMAIN="$domain"
    export POSTGRES_HOST="postgres.${INFRA_DOMAIN}"
    export REDIS_HOST="redis.${INFRA_DOMAIN}"
    export MINIO_HOST="minio.${INFRA_DOMAIN}"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run with sudo."
        exit 1
    fi
}

validate_project() {
    if [[ ! "$1" =~ ^[a-z][a-z0-9]{2,29}$ ]]; then
        echo "Invalid project name: $1" >&2
        return 1
    fi
    return 0
}

generate_password() {
    openssl rand -hex 24
}

require_container() {
    local container="$1"

    if [ "$(docker inspect -f '{{.State.Running}}' \
        "$container" 2>/dev/null)" != "true" ]; then

        echo "Container $container is not running."
        return 1
    fi
    return 0
}

init_project_paths() {
    PROJECT="$1"

    PROJECT_DIR="$PROJECTS_DIR/$PROJECT"
    ENV_FILE="$PROJECT_DIR/.env"
    MANIFEST="$PROJECT_DIR/project.json"

    DB_NAME="${PROJECT}_db"
    DB_USER="${PROJECT}_user"

    REDIS_USER="${PROJECT}_user"

    MINIO_USER="${PROJECT}_user"
    MINIO_BUCKET="$PROJECT"
    MINIO_POLICY="${PROJECT}-policy"
    return 0
}

init_manifest() {
    if [ "$#" -eq 0 ]; then
        jq -n --arg name "$PROJECT" '{
            name: $name,
            services: {
                postgres: false,
                redis: false,
                minio: false
            },
            status: "provisioning"
        }' > "$MANIFEST"
    else
        jq -n --arg name "$PROJECT" --args '
            $ARGS.positional as $ids |
            {
                name: $name,
                services: (reduce $ids[] as $id ({}; .[$id] = false)),
                status: "provisioning"
            }
        ' "$@" > "$MANIFEST"
    fi

    chmod 600 "$MANIFEST"
    return 0
}

set_service_state() {
    local service="$1"
    local state="$2"
    local temp

    temp="$(mktemp "$PROJECT_DIR/.manifest.XXXXXX")"

    jq \
        --arg service "$service" \
        --argjson state "$state" \
        '.services[$service] = $state' \
        "$MANIFEST" > "$temp"

    mv -f "$temp" "$MANIFEST"
    return 0
}

set_project_status() {
    local status="$1"
    local temp

    temp="$(mktemp "$PROJECT_DIR/.manifest.XXXXXX")"

    jq --arg status "$status" \
        '.status = $status' \
        "$MANIFEST" > "$temp"

    mv -f "$temp" "$MANIFEST"
    return 0
}

has_service() {
    jq -e --arg service "$1" \
        '.services[$service] == true' \
        "$MANIFEST" >/dev/null
}

require_managed_project() {
    if [ ! -f "$MANIFEST" ]; then
        echo "Project manifest not found."
        echo "Legacy projects require migration first."
        return 1
    fi

    if [ ! -f "$ENV_FILE" ]; then
        echo "Project environment file not found: $ENV_FILE" >&2
        return 1
    fi

    if ! jq -e --arg name "$PROJECT" '
        .name == $name and
        .status == "provisioned" and
        (.services | type == "object") and
        ([.services[] | type == "boolean"] | all)
    ' "$MANIFEST" >/dev/null; then
        echo "Invalid or incomplete project manifest."
        return 1
    fi
    return 0
}

remove_env_vars() {
    local pattern="$1"
    local temp

    temp="$(mktemp "$PROJECT_DIR/.env.XXXXXX")"

    awk -F= -v pattern="$pattern" \
        '$1 !~ pattern' "$ENV_FILE" > "$temp"

    chmod 600 "$temp"
    mv -f "$temp" "$ENV_FILE"
    return 0
}

ensure_private_dirs() {
    if [ "${INFRA_TEST_MODE:-0}" = "1" ]; then
        mkdir -p "$@"
    else
        install -d -m 700 "$@"
    fi
    return 0
}

acquire_project_lock() {
    ensure_private_dirs "$INFRA_ROOT/state"

    exec 9>"$INFRA_ROOT/state/provisioning.lock"

    flock -n 9 || {
        echo "Another provisioning task is running."
        return 1
    }
    return 0
}

acquire_destructive_project_locks() {
    ensure_private_dirs "$INFRA_ROOT/backup" "$INFRA_ROOT/state"

    exec 8>"$INFRA_ROOT/backup/backup.lock"
    flock -n 8 || {
        echo "A backup, deployment or infrastructure sync is running." >&2
        return 1
    }

    exec 9>"$INFRA_ROOT/state/provisioning.lock"
    flock -n 9 || {
        echo "Another project operation or deployment is running." >&2
        return 1
    }

    export BACKUP_LOCK_HELD=1
    return 0
}

acquire_restore_locks() {
    ensure_private_dirs "$INFRA_ROOT/backup" "$INFRA_ROOT/state"

    exec 8>"$INFRA_ROOT/backup/backup.lock"
    flock -n 8 || {
        echo "A backup, deployment or infrastructure sync is running." >&2
        return 1
    }

    exec 7>"$INFRA_ROOT/state/provisioning.lock"
    flock -n 7 || {
        echo "A project operation or deployment is running." >&2
        return 1
    }

    exec 6>"$INFRA_ROOT/state/restore.lock"
    flock -n 6 || {
        echo "Another restore or update is running." >&2
        return 1
    }
    return 0
}
