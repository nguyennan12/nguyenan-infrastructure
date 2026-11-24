#!/usr/bin/env bash

PROJECTS_DIR="/opt/infra/projects"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run with sudo."
        exit 1
    fi
}

validate_project() {
    if [[ ! "$1" =~ ^[a-z][a-z0-9]{2,29}$ ]]; then
        echo "Invalid project name."
        exit 1
    fi
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
}

init_manifest() {
    jq -n --arg name "$PROJECT" '{
        name: $name,
        services: {
            postgres: false,
            redis: false,
            minio: false
        },
        status: "provisioning"
    }' > "$MANIFEST"

    chmod 600 "$MANIFEST"
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
}

set_project_status() {
    local status="$1"
    local temp

    temp="$(mktemp "$PROJECT_DIR/.manifest.XXXXXX")"

    jq --arg status "$status" \
        '.status = $status' \
        "$MANIFEST" > "$temp"

    mv -f "$temp" "$MANIFEST"
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
        exit 1
    fi

    test -f "$ENV_FILE"

    if ! jq -e --arg name "$PROJECT" '
        .name == $name and
        .status == "provisioned" and
        (.services.postgres | type == "boolean") and
        (.services.redis | type == "boolean") and
        (.services.minio | type == "boolean")
    ' "$MANIFEST" >/dev/null; then
        echo "Invalid or incomplete project manifest."
        exit 1
    fi
}

remove_env_vars() {
    local pattern="$1"
    local temp

    temp="$(mktemp "$PROJECT_DIR/.env.XXXXXX")"

    awk -F= -v pattern="$pattern" \
        '$1 !~ pattern' "$ENV_FILE" > "$temp"

    chmod 600 "$temp"
    mv -f "$temp" "$ENV_FILE"
}

acquire_project_lock() {
    install -d -m 700 /opt/infra/state

    exec 9>/opt/infra/state/provisioning.lock

    flock -n 9 || {
        echo "Another provisioning task is running."
        exit 1
    }
}