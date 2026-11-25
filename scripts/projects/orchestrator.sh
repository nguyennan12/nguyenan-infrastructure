#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../core/common.sh" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    SCRIPTS_ROOT="$SCRIPT_DIR"
fi
source "$SCRIPTS_ROOT/core/common.sh"
source "$SCRIPTS_ROOT/core/registry.sh"

usage_for_command() {
    case "${1:-}" in
        create) echo "Usage: create-project.sh <project-name> [--services id1,id2|--postgres|--redis|--minio|--all]" ;;
        add) echo "Usage: add-service.sh <project-name> [--services id1,id2|--postgres|--redis|--minio|--all]" ;;
        remove) echo "Usage: remove-service.sh <project-name> [--services id1,id2|--postgres|--redis|--minio]" ;;
        delete) echo "Usage: delete-project.sh <project-name>" ;;
        list) echo "Usage: list-projects.sh" ;;
        *) echo "Usage: project-services.sh {create|add|remove|delete|list} [arguments]" ;;
    esac
}

COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
    echo "Missing project service command." >&2
    usage_for_command >&2
    exit 1
fi
if [ "$COMMAND" = "--help" ] || [ "$COMMAND" = "-h" ]; then
    usage_for_command
    exit 0
fi
shift

case "$COMMAND" in
    create|add|remove|delete|list) ;;
    *) echo "Unknown project service command: $COMMAND" >&2; usage_for_command >&2; exit 1 ;;
esac

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage_for_command "$COMMAND"
    exit 0
fi

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != "1" ]; then
    echo "Please run with sudo."
    exit 1
fi
if ! registry_validate; then
    echo "Installed service registry is invalid; refusing project provisioning." >&2
    exit 1
fi

declare -a REQUESTED_SERVICES=()
declare -a ORDERED_SERVICES=()
declare -A REQUESTED_SET=()
ALL_REQUESTED=false

add_requested_service() {
    local service="$1"
    [ -n "$service" ] || return 0
    if [ -z "${REQUESTED_SET[$service]:-}" ]; then
        REQUESTED_SERVICES+=("$service")
        REQUESTED_SET[$service]=1
    fi
    return 0
}

add_csv_services() {
    local csv="$1"
    local service
    IFS=',' read -r -a csv_services <<< "$csv"
    for service in "${csv_services[@]}"; do
        add_requested_service "$service"
    done
    return 0
}

parse_service_arguments() {
    local allow_interactive="$1"
    shift

    if [ "$#" -eq 0 ] && [ "$allow_interactive" = "true" ]; then
        interactive_service_selection
        return 0
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --services)
                [ "$#" -ge 2 ] || { echo "--services requires a comma-separated value." >&2; usage_for_command "$COMMAND" >&2; return 1; }
                add_csv_services "$2"
                shift 2
                ;;
            --services=*) add_csv_services "${1#--services=}"; shift ;;
            --postgres) add_requested_service postgres; shift ;;
            --redis) add_requested_service redis; shift ;;
            --minio) add_requested_service minio; shift ;;
            --all)
                ALL_REQUESTED=true
                while IFS= read -r service; do add_requested_service "$service"; done < <(registry_enabled_project_services)
                shift
                ;;
            *) echo "Unknown service argument: $1" >&2; usage_for_command "$COMMAND" >&2; return 1 ;;
        esac
    done
    return 0
}

interactive_service_selection() {
    local -a choices=()
    local -a services=()
    local service display available index=1 choice

    echo "Registered project services:"
    while IFS= read -r service; do
        display="$(registry_service_get "$service" | jq -r '.display_name')"
        if registry_service_available "$service"; then available=available; else available=unavailable; fi
        printf '  %d. %s (%s, %s)\n' "$index" "$display" "$service" "$available"
        services+=("$service")
        index=$((index + 1))
    done < <(registry_enabled_project_services)

    read -r -p "Select service numbers separated by spaces: " -a choices
    for choice in "${choices[@]}"; do
        [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Invalid service selection." >&2; exit 1; }
        [ "$choice" -ge 1 ] && [ "$choice" -le "${#services[@]}" ] || { echo "Invalid service selection." >&2; exit 1; }
        add_requested_service "${services[$((choice - 1))]}"
    done
    return 0
}

validate_and_order_services() {
    local service dependency
    local -a filtered=()

    [ "${#REQUESTED_SERVICES[@]}" -gt 0 ] || { echo "Select at least one service." >&2; return 1; }
    ORDERED_SERVICES=()

    for service in "${REQUESTED_SERVICES[@]}"; do
        registry_service_get "$service" >/dev/null 2>&1 || { echo "Unknown registered service: $service" >&2; return 1; }
        registry_service_has_capability "$service" project-provision || { echo "Service is not project-provisionable: $service" >&2; return 1; }
        registry_service_enabled "$service" || { echo "Service is registered but disabled: $service" >&2; return 1; }

        if ! registry_service_available "$service"; then
            if $ALL_REQUESTED; then
                echo "Skipping unavailable service selected by --all: $service"
                unset 'REQUESTED_SET[$service]'
                continue
            fi
            echo "Service is not available for provisioning: $service" >&2
            return 1
        fi
        filtered+=("$service")
    done
    REQUESTED_SERVICES=("${filtered[@]}")
    [ "${#REQUESTED_SERVICES[@]}" -gt 0 ] || { echo "No enabled and available project services were found." >&2; return 1; }

    for service in "${REQUESTED_SERVICES[@]}"; do
        while IFS= read -r dependency; do
            [ -n "$dependency" ] || continue
            if [ -z "${REQUESTED_SET[$dependency]:-}" ] &&
               { [ ! -f "${MANIFEST:-}" ] || ! has_service "$dependency" 2>/dev/null; }; then
                echo "Service $service requires project service $dependency." >&2
                return 1
            fi
        done < <(registry_service_get "$service" | jq -r '.dependencies[]?')
    done

    while IFS= read -r service; do
        if [ -n "${REQUESTED_SET[$service]:-}" ]; then
            ORDERED_SERVICES+=("$service")
        fi
    done < <(registry_service_order)
    [ "${#ORDERED_SERVICES[@]}" -gt 0 ] || { echo "No requested services remained after dependency ordering." >&2; return 1; }
    return 0
}

run_service_hook() {
    local service="$1"
    local hook="$2"
    registry_run_service_hook "$service" validate_configuration
    registry_run_service_hook "$service" "$hook"
    return 0
}

print_service_states() {
    jq '.services' "$MANIFEST"
    return 0
}

create_project_registry() {
    local service
    [ "$#" -ge 1 ] || { usage_for_command create >&2; return 1; }
    PROJECT="$1"; shift
    if ! validate_project "$PROJECT"; then usage_for_command create >&2; return 1; fi
    init_project_paths "$PROJECT"
    parse_service_arguments true "$@"

    ensure_private_dirs "$PROJECTS_DIR" "$INFRA_ROOT/state"
    acquire_project_lock
    [ ! -e "$PROJECT_DIR" ] || { echo "Project already exists." >&2; exit 1; }

    validate_and_order_services

    mkdir -m 700 "$PROJECT_DIR"
    printf 'PROJECT_NAME=%s\n' "$PROJECT" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    mapfile -t ALL_REGISTRY_SERVICES < <(registry_enabled_project_services)
    init_manifest "${ALL_REGISTRY_SERVICES[@]}"

    echo "Project: $PROJECT"
    printf 'Services: %s\n' "${ORDERED_SERVICES[*]}"
    read -r -p "Type CREATE $PROJECT to continue: " CONFIRM
    [ "$CONFIRM" = "CREATE $PROJECT" ] || { echo "Provisioning cancelled."; rm -rf -- "$PROJECT_DIR"; exit 1; }

    trap 'rc=$?; if [ "$rc" -ne 0 ]; then set_project_status incomplete || true; echo "Provisioning failed. Review partial resources."; fi' EXIT
    for service in "${ORDERED_SERVICES[@]}"; do run_service_hook "$service" provision; done
    set_project_status provisioned
    trap - EXIT
    echo "Project created successfully: $PROJECT"
    print_service_states
    return 0
}

add_services_registry() {
    local service
    [ "$#" -ge 2 ] || { usage_for_command add >&2; return 1; }
    PROJECT="$1"; shift
    if ! validate_project "$PROJECT"; then usage_for_command add >&2; return 1; fi
    init_project_paths "$PROJECT"; acquire_project_lock; require_managed_project
    parse_service_arguments false "$@"

    for service in "${REQUESTED_SERVICES[@]}"; do
        if has_service "$service"; then unset 'REQUESTED_SET[$service]'; fi
    done
    REQUESTED_SERVICES=()
    for service in "${!REQUESTED_SET[@]}"; do REQUESTED_SERVICES+=("$service"); done
    if [ "${#REQUESTED_SERVICES[@]}" -eq 0 ]; then
        echo "No new services to provision."
        return 0
    fi
    validate_and_order_services

    printf 'Services to add: %s\n' "${ORDERED_SERVICES[*]}"
    read -r -p "Type ADD $PROJECT to continue: " CONFIRM
    [ "$CONFIRM" = "ADD $PROJECT" ] || { echo "Operation cancelled."; exit 1; }
    set_project_status provisioning
    trap 'rc=$?; if [ "$rc" -ne 0 ]; then set_project_status incomplete || true; echo "Provisioning failed. Review partial resources."; fi' EXIT
    for service in "${ORDERED_SERVICES[@]}"; do run_service_hook "$service" provision; done
    set_project_status provisioned
    trap - EXIT
    echo "Services added successfully."
    print_service_states
    return 0
}

validate_remove_dependencies() {
    local service dependent
    for service in "${REQUESTED_SERVICES[@]}"; do
        while IFS= read -r dependent; do
            [ -n "$dependent" ] || continue
            if has_service "$dependent" && [ -z "${REQUESTED_SET[$dependent]:-}" ]; then
                echo "Cannot remove $service while dependent service $dependent remains enabled." >&2
                exit 1
            fi
        done < <(jq -r --arg dependency "$service" '.services[] | select(.dependencies | index($dependency)) | .id' "$SERVICE_REGISTRY")
    done
    return 0
}

remove_services_registry() {
    local service index
    [ "$#" -ge 2 ] || { usage_for_command remove >&2; return 1; }
    PROJECT="$1"; shift
    if ! validate_project "$PROJECT"; then usage_for_command remove >&2; return 1; fi
    init_project_paths "$PROJECT"; acquire_destructive_project_locks; require_managed_project
    parse_service_arguments false "$@"

    for service in "${REQUESTED_SERVICES[@]}"; do
        if ! has_service "$service"; then unset 'REQUESTED_SET[$service]'; fi
    done
    REQUESTED_SERVICES=()
    for service in "${!REQUESTED_SET[@]}"; do REQUESTED_SERVICES+=("$service"); done
    if [ "${#REQUESTED_SERVICES[@]}" -eq 0 ]; then
        echo "No matching services to remove."
        return 0
    fi
    validate_and_order_services
    validate_remove_dependencies

    printf 'Services to remove: %s\n' "${ORDERED_SERVICES[*]}"
    echo "WARNING: Selected service data will be deleted after a successful backup."
    read -r -p "Type REMOVE $PROJECT to continue: " CONFIRM
    [ "$CONFIRM" = "REMOVE $PROJECT" ] || { echo "Operation cancelled."; exit 1; }
    "$INFRA_ROOT/backup/backup-all.sh"
    set_project_status removing
    trap 'rc=$?; if [ "$rc" -ne 0 ]; then set_project_status incomplete || true; echo "Removal failed. Review partial resources."; fi' EXIT
    for ((index=${#ORDERED_SERVICES[@]}-1; index>=0; index--)); do
        run_service_hook "${ORDERED_SERVICES[$index]}" remove
    done
    set_project_status provisioned
    trap - EXIT
    echo "Services removed successfully."
    print_service_states
    return 0
}

delete_project_registry() {
    local service index
    [ "$#" -eq 1 ] || { usage_for_command delete >&2; return 1; }
    PROJECT="$1"
    if ! validate_project "$PROJECT"; then usage_for_command delete >&2; return 1; fi
    init_project_paths "$PROJECT"; acquire_destructive_project_locks; require_managed_project
    mapfile -t REQUESTED_SERVICES < <(jq -r '.services | to_entries[] | select(.value == true) | .key' "$MANIFEST")
    for service in "${REQUESTED_SERVICES[@]}"; do
        registry_service_get "$service" >/dev/null 2>&1 || { echo "Enabled project service is no longer registered: $service" >&2; exit 1; }
        REQUESTED_SET[$service]=1
    done
    if [ "${#REQUESTED_SERVICES[@]}" -gt 0 ]; then validate_and_order_services; fi

    print_service_states
    echo "WARNING: All registered project resources will be deleted after a successful backup."
    read -r -p "Type DELETE $PROJECT to continue: " CONFIRM
    [ "$CONFIRM" = "DELETE $PROJECT" ] || { echo "Deletion cancelled."; exit 1; }
    "$INFRA_ROOT/backup/backup-all.sh"
    set_project_status deleting
    trap 'rc=$?; if [ "$rc" -ne 0 ]; then set_project_status incomplete || true; echo "Deletion failed. Review remaining resources."; fi' EXIT
    for ((index=${#ORDERED_SERVICES[@]}-1; index>=0; index--)); do
        run_service_hook "${ORDERED_SERVICES[$index]}" remove
    done
    jq -e '.services | all(.[]; . == false)' "$MANIFEST" >/dev/null
    rm -rf -- "$PROJECT_DIR"
    trap - EXIT
    echo "Project deleted successfully: $PROJECT"
    return 0
}

list_projects_registry() {
    local dir manifest project status services count=0
    [ "$#" -eq 0 ] || { echo "Unexpected arguments for list-projects.sh." >&2; usage_for_command list >&2; return 1; }
    printf '%-24s %-18s %s\n' PROJECT STATUS SERVICES
    printf '%s\n' '-----------------------------------------------------------------------'
    if [ -d "$PROJECTS_DIR" ]; then
        for dir in "$PROJECTS_DIR"/*; do
            [ -d "$dir" ] || continue
            project="$(basename "$dir")"; manifest="$dir/project.json"
            if [ -f "$manifest" ]; then
                status="$(jq -r '.status // "unknown"' "$manifest")"
                services="$(jq -r '[.services | to_entries[] | select(.value == true) | .key] | join(",")' "$manifest")"
            elif [ -f "$dir/.provisioned" ]; then
                status=Legacy; services=postgres,redis,minio
            else
                status=Incomplete; services='?'
            fi
            printf '%-24s %-18s %s\n' "$project" "$status" "${services:--}"
            count=$((count + 1))
        done
    fi
    echo "Total managed projects: $count"
    return 0
}

case "$COMMAND" in
    create) create_project_registry "$@" ;;
    add) add_services_registry "$@" ;;
    remove) remove_services_registry "$@" ;;
    delete) delete_project_registry "$@" ;;
    list) list_projects_registry "$@" ;;
    *) echo "Unknown project service command: $COMMAND" >&2; usage_for_command >&2; exit 1 ;;
esac
