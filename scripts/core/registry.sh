#!/usr/bin/env bash

REGISTRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"

if [ -z "${REGISTRY_ROOT:-}" ]; then
    REGISTRY_SOURCE_CANDIDATE="$(cd "$REGISTRY_LIB_DIR/../.." && pwd)/registry"
    if [ -f "$REGISTRY_SOURCE_CANDIDATE/stacks.json" ]; then
        REGISTRY_ROOT="$REGISTRY_SOURCE_CANDIDATE"
    else
        REGISTRY_ROOT="$INFRA_ROOT/registry"
    fi
fi

REGISTRY_TRUSTED_ROOT="${REGISTRY_TRUSTED_ROOT:-$(dirname "$REGISTRY_ROOT")}"
STACK_REGISTRY="${STACK_REGISTRY:-$REGISTRY_ROOT/stacks.json}"
SERVICE_REGISTRY="${SERVICE_REGISTRY:-$REGISTRY_ROOT/services.json}"

registry_available() {
    [ -s "$STACK_REGISTRY" ] && [ -s "$SERVICE_REGISTRY" ] && command -v jq >/dev/null
}

registry_validate_identifier() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]
}

registry_resolve_path() {
    local relative="$1"
    local resolved

    if [ -z "$relative" ] || [[ "$relative" = /* ]] || [[ "$relative" == *\\* ]] ||
       [[ "/$relative/" == */../* ]]; then
        echo "Unsafe registry path: $relative" >&2
        return 1
    fi

    resolved="$(realpath -m "$REGISTRY_TRUSTED_ROOT/$relative")"
    case "$resolved" in
        "$REGISTRY_TRUSTED_ROOT"/*) printf '%s\n' "$resolved" ;;
        *) echo "Registry path escapes trusted root: $relative" >&2; return 1 ;;
    esac
}

registry_stack_get() {
    jq -ce --arg id "$1" '.stacks[] | select(.id == $id)' "$STACK_REGISTRY"
}

registry_service_get() {
    jq -ce --arg id "$1" '.services[] | select(.id == $id)' "$SERVICE_REGISTRY"
}

registry_list_stacks() {
    jq -r '.stacks[].id' "$STACK_REGISTRY" | sort
}

registry_list_services() {
    jq -r '.services[].id' "$SERVICE_REGISTRY" | sort
}

registry_enabled_project_services() {
    jq -r '.services[] | select(.enabled == true and (.capabilities | index("project-provision"))) | .id' \
        "$SERVICE_REGISTRY" | sort
}

registry_service_enabled() {
    jq -e --arg id "$1" '.services[] | select(.id == $id and .enabled == true)' \
        "$SERVICE_REGISTRY" >/dev/null
}

registry_service_has_capability() {
    jq -e --arg id "$1" --arg capability "$2" \
        '.services[] | select(.id == $id and (.capabilities | index($capability)))' \
        "$SERVICE_REGISTRY" >/dev/null
}

registry_stack_enabled() {
    jq -e --arg id "$1" '.stacks[] | select(.id == $id and .enabled == true)' \
        "$STACK_REGISTRY" >/dev/null
}

registry_service_module() {
    local relative
    relative="$(registry_service_get "$1" | jq -r '.module')"
    registry_resolve_path "$relative"
}

registry_run_service_hook() {
    local service="$1"
    local hook="$2"
    local module
    shift 2

    case "$hook" in
        validate_configuration|is_available|health|backup_available|provision|remove|generate_connection_config) ;;
        *) echo "Unknown standardized service hook: $hook" >&2; return 1 ;;
    esac

    module="$(registry_service_module "$service")"
    [ -f "$module" ] || { echo "Service module is missing: $module" >&2; return 1; }

    (
        source "$module"
        if ! declare -F "service_$hook" >/dev/null; then
            echo "Service $service does not implement service_$hook" >&2
            exit 1
        fi
        "service_$hook" "$@"
    )
}

registry_service_available() {
    registry_service_enabled "$1" && registry_run_service_hook "$1" is_available >/dev/null 2>&1
}

registry_service_health() {
    registry_run_service_hook "$1" health
}

declare -gA REGISTRY_STACK_VISIT=()
declare -gA REGISTRY_SERVICE_VISIT=()

registry__visit_stack() {
    local id="$1"
    local state="${REGISTRY_STACK_VISIT[$id]:-0}"
    local dependency

    [ "$state" != "2" ] || return 0
    if [ "$state" = "1" ]; then
        echo "Stack dependency cycle detected at: $id" >&2
        return 1
    fi

    REGISTRY_STACK_VISIT[$id]=1
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        registry__visit_stack "$dependency" || return 1
    done < <(registry_stack_get "$id" | jq -r '.dependencies[]?' | sort)
    REGISTRY_STACK_VISIT[$id]=2
    printf '%s\n' "$id"
}

registry_stack_order() {
    local id
    REGISTRY_STACK_VISIT=()
    while IFS= read -r id; do
        registry__visit_stack "$id" || return 1
    done < <(jq -r '.stacks[] | select(.enabled == true) | .id' "$STACK_REGISTRY" | sort)
}

registry__visit_service() {
    local id="$1"
    local state="${REGISTRY_SERVICE_VISIT[$id]:-0}"
    local dependency

    [ "$state" != "2" ] || return 0
    if [ "$state" = "1" ]; then
        echo "Service dependency cycle detected at: $id" >&2
        return 1
    fi

    REGISTRY_SERVICE_VISIT[$id]=1
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        registry__visit_service "$dependency" || return 1
    done < <(registry_service_get "$id" | jq -r '.dependencies[]?' | sort)
    REGISTRY_SERVICE_VISIT[$id]=2
    printf '%s\n' "$id"
}

registry_service_order() {
    local id
    REGISTRY_SERVICE_VISIT=()
    while IFS= read -r id; do
        registry__visit_service "$id" || return 1
    done < <(registry_list_services)
    return 0
}

registry_backup_services() {
    jq -r '.services
        | map(select(.enabled == true and (.capabilities | index("backup"))))
        | sort_by(.backup.order, .id)
        | .[].id' "$SERVICE_REGISTRY"
}

registry_restore_plan() {
    jq -r '
        def phase_order:
          if . == "infrastructure" then 10
          elif . == "before-service-start" then 20
          elif . == "after-database-start" then 30
          elif . == "after-service-start" then 40
          elif . == "final-verification" then 50
          else 999 end;
        .services
        | map(select(.enabled == true and (.capabilities | index("restore"))))
        | sort_by((.restore.phase | phase_order), .restore.order, .id)
        | .[]
        | [.id, .restore.phase, .restore.script, .backup.tag] | @tsv
    ' "$SERVICE_REGISTRY"
}

registry_required_environment() {
    jq -r '.stacks[] | select(.enabled == true) | .required_env[]' "$STACK_REGISTRY" | sort -u
}

registry_secret_definitions() {
    jq -r '.stacks[] | select(.enabled == true) as $stack
        | $stack.secrets[]?
        | [$stack.id, $stack.secret_file, .name, .generator, (.default // "")] | @tsv' \
        "$STACK_REGISTRY"
}

registry_sync_manifest() {
    jq -r '.services[].managed_files[] | [.source, .destination] | @tsv' \
        "$SERVICE_REGISTRY" | sort -u
}

registry_service_managed_file() {
    local service="$1"
    local source="$2"
    local candidate destination

    candidate="$(registry_resolve_path "$source")" || return 1
    if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    destination="$(registry_service_get "$service" | jq -r --arg source "$source" \
        '.managed_files[] | select(.source == $source) | .destination' | head -n 1)"
    [ -n "$destination" ] || return 1
    candidate="$(registry_resolve_path "$destination")" || return 1
    [ -f "$candidate" ] || return 1
    printf '%s\n' "$candidate"
}

registry_validate_module() {
    local id="$1"
    local module="$2"
    local capabilities="$3"

    (
        source "$module"
        if grep -Fqw project-provision <<< "$capabilities"; then
            for hook in validate_configuration is_available health provision remove generate_connection_config; do
                declare -F "service_$hook" >/dev/null || {
                    echo "Service $id is missing standardized hook service_$hook" >&2
                    exit 1
                }
            done
        fi
        if grep -Fqw backup <<< "$capabilities"; then
            declare -F service_backup_available >/dev/null || {
                echo "Service $id is missing standardized hook service_backup_available" >&2
                exit 1
            }
        fi
    )
}

registry_validate() {
    local id path destination capabilities dependency stack handler readiness secret_file variable

    registry_available || { echo "Registry files or jq are unavailable." >&2; return 1; }
    jq -e '.version == 1 and (.stacks | type == "array")' "$STACK_REGISTRY" >/dev/null || return 1
    jq -e '.version == 1 and (.services | type == "array")' "$SERVICE_REGISTRY" >/dev/null || return 1

    if jq -e '[.stacks[].id] | group_by(.) | any(length > 1)' "$STACK_REGISTRY" >/dev/null; then
        echo "Duplicate stack identifier detected." >&2
        return 1
    fi
    if jq -e '[.services[].id] | group_by(.) | any(length > 1)' "$SERVICE_REGISTRY" >/dev/null; then
        echo "Duplicate service identifier detected." >&2
        return 1
    fi
    if jq -e '[.stacks[].project_name] | group_by(.) | any(length > 1)' "$STACK_REGISTRY" >/dev/null; then
        echo "Duplicate Compose project name detected." >&2
        return 1
    fi
    if jq -e '[.services[].managed_files[].destination] | group_by(.) | any(length > 1)' "$SERVICE_REGISTRY" >/dev/null; then
        echo "Duplicate managed-file destination detected." >&2
        return 1
    fi
    if jq -e '[.stacks[].secrets[].name] | group_by(.) | any(length > 1)' "$STACK_REGISTRY" >/dev/null; then
        echo "A secret variable is assigned to multiple stack secret files." >&2
        return 1
    fi

    while IFS= read -r id; do
        registry_validate_identifier "$id" || { echo "Invalid stack identifier: $id" >&2; return 1; }
        path="$(registry_stack_get "$id" | jq -r '.compose_file')"
        [[ "$path" =~ ^stacks/[a-z0-9-]+\.yml$ ]] || { echo "Invalid Compose path for $id" >&2; return 1; }
        path="$(registry_resolve_path "$path")"
        [ -f "$path" ] || { echo "Compose file is missing for $id" >&2; return 1; }

        registry_stack_get "$id" | jq -e '
            (.enabled | type == "boolean") and
            (.required | type == "boolean") and
            (.project_name | type == "string") and
            (.dependencies | type == "array") and
            (.containers | type == "array") and
            (.volumes | type == "array") and
            (.required_env | type == "array") and
            (.secrets | type == "array")
        ' >/dev/null || { echo "Invalid stack metadata: $id" >&2; return 1; }
        registry_stack_get "$id" | jq -e '
            (.project_name | test("^infra-[a-z0-9-]+$")) and
            ([.containers[] | test("^[a-zA-Z0-9][a-zA-Z0-9_.-]+$")] | all) and
            ([.volumes[] | test("^[a-zA-Z0-9][a-zA-Z0-9_.-]+$")] | all)
        ' >/dev/null || { echo "Unsafe runtime resource name in stack: $id" >&2; return 1; }

        handler="$(registry_stack_get "$id" | jq -r '.handler')"
        case "$handler" in gateway|database|cache|storage|generic) ;; *) echo "Unknown stack handler: $handler" >&2; return 1 ;; esac
        readiness="$(registry_stack_get "$id" | jq -r '.readiness')"
        case "$readiness" in container-running|postgres-pgbouncer|redis|minio) ;; *) echo "Unknown readiness type: $readiness" >&2; return 1 ;; esac
        secret_file="$(registry_stack_get "$id" | jq -r '.secret_file')"
        [[ "$secret_file" =~ ^[a-z0-9-]+\.env$ ]] || { echo "Invalid secret file reference: $secret_file" >&2; return 1; }
        if [ "$handler" = "generic" ] && [ "$readiness" != "container-running" ]; then
            echo "Generic stack $id must use container-running readiness." >&2
            return 1
        fi

        while IFS=$'\t' read -r variable generator; do
            [[ "$variable" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "Invalid secret variable in stack $id" >&2; return 1; }
            case "$generator" in password|prompt-email|literal) ;; *) echo "Unknown secret generator in stack $id: $generator" >&2; return 1 ;; esac
            registry_stack_get "$id" | jq -e --arg variable "$variable" '.required_env | index($variable)' >/dev/null || {
                echo "Secret variable $variable is not declared in required_env for stack $id" >&2
                return 1
            }
        done < <(registry_stack_get "$id" | jq -r '.secrets[] | [.name, .generator] | @tsv')

        while IFS= read -r variable; do
            [[ "$variable" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "Invalid environment variable in stack $id" >&2; return 1; }
        done < <(registry_stack_get "$id" | jq -r '.required_env[]')

        while IFS= read -r dependency; do
            registry_stack_get "$dependency" >/dev/null 2>&1 || { echo "Unknown stack dependency $dependency for $id" >&2; return 1; }
            if registry_stack_enabled "$id" && ! registry_stack_enabled "$dependency"; then
                echo "Enabled stack $id depends on disabled stack $dependency" >&2
                return 1
            fi
        done < <(registry_stack_get "$id" | jq -r '.dependencies[]?')
    done < <(registry_list_stacks)

    registry_stack_order >/dev/null || return 1

    while IFS= read -r id; do
        registry_validate_identifier "$id" || { echo "Invalid service identifier: $id" >&2; return 1; }
        stack="$(registry_service_get "$id" | jq -r '.stack')"
        registry_stack_get "$stack" >/dev/null 2>&1 || { echo "Unknown stack $stack for service $id" >&2; return 1; }
        if registry_service_enabled "$id" && ! registry_stack_enabled "$stack"; then
            echo "Enabled service $id belongs to disabled stack $stack" >&2
            return 1
        fi
        path="$(registry_service_get "$id" | jq -r '.module')"
        [[ "$path" =~ ^scripts/services/[a-z0-9-]+/adapter\.sh$ ]] || { echo "Invalid service module path: $path" >&2; return 1; }
        path="$(registry_resolve_path "$path")"
        [ -f "$path" ] || { echo "Service module is missing for $id" >&2; return 1; }
        registry_service_get "$id" | jq -e '
            (.enabled | type == "boolean") and
            (.dependencies | type == "array") and
            (.capabilities | type == "array") and
            (.project_env | type == "array") and
            (.managed_files | type == "array")
        ' >/dev/null || { echo "Invalid service metadata: $id" >&2; return 1; }
        registry_service_get "$id" | jq -e '
            ([.project_env[] | test("^[A-Z][A-Z0-9_]*$")] | all) and
            ([.dependencies[] | test("^[a-z][a-z0-9-]{1,30}$")] | all)
        ' >/dev/null || { echo "Invalid project environment or dependency metadata: $id" >&2; return 1; }

        capabilities="$(registry_service_get "$id" | jq -r '.capabilities | join(" ")')"
        for capability in $capabilities; do
            case "$capability" in project-provision|health|backup|restore) ;; *) echo "Unknown capability $capability for $id" >&2; return 1 ;; esac
        done
        registry_validate_module "$id" "$path" "$capabilities" || return 1

        while IFS= read -r dependency; do
            registry_service_get "$dependency" >/dev/null 2>&1 || { echo "Unknown service dependency $dependency for $id" >&2; return 1; }
            if registry_service_enabled "$id" && ! registry_service_enabled "$dependency"; then
                echo "Enabled service $id depends on disabled service $dependency" >&2
                return 1
            fi
        done < <(registry_service_get "$id" | jq -r '.dependencies[]?')

        if registry_service_has_capability "$id" backup; then
            registry_service_get "$id" | jq -e '
                (.backup.order | type == "number") and
                (.backup.required_when_enabled | type == "boolean") and
                (.backup.tag | test("^[a-z][a-z0-9-]{1,40}$"))
            ' >/dev/null || { echo "Invalid backup metadata for $id" >&2; return 1; }
            path="$(registry_service_get "$id" | jq -r '.backup.script')"
            [[ "$path" =~ ^scripts/services/[a-z0-9-]+/backup\.sh$ ]] || { echo "Invalid backup hook path for $id" >&2; return 1; }
            registry_service_managed_file "$id" "$path" >/dev/null || { echo "Missing backup hook for $id" >&2; return 1; }
        fi
        if registry_service_has_capability "$id" restore; then
            registry_service_get "$id" | jq -e '(.restore.order | type == "number")' >/dev/null || {
                echo "Invalid restore order for $id" >&2
                return 1
            }
            path="$(registry_service_get "$id" | jq -r '.restore.script')"
            [[ "$path" =~ ^scripts/services/[a-z0-9-]+/restore\.sh$ ]] || { echo "Invalid restore hook path for $id" >&2; return 1; }
            registry_service_managed_file "$id" "$path" >/dev/null || { echo "Missing restore hook for $id" >&2; return 1; }
            case "$(registry_service_get "$id" | jq -r '.restore.phase')" in
                before-service-start|after-database-start|after-service-start|final-verification) ;;
                *) echo "Invalid restore phase for $id" >&2; return 1 ;;
            esac
        fi

        while IFS=$'\t' read -r path destination; do
            [ -n "$path" ] || continue
            if [[ ! "$destination" =~ ^(scripts/services/[a-z0-9-]+/(adapter|provision)\.sh|scripts/restore-[a-z0-9-]+\.sh|backup/backup-[a-z0-9-]+\.sh)$ ]]; then
                echo "Unsafe managed-file destination for $id: $destination" >&2
                return 1
            fi
            registry_service_managed_file "$id" "$path" >/dev/null || { echo "Managed source or installed file is missing for $id" >&2; return 1; }
        done < <(registry_service_get "$id" | jq -r '.managed_files[] | [.source, .destination] | @tsv')
    done < <(registry_list_services)

    registry_service_order >/dev/null || return 1
}
