#!/usr/bin/env bash

SERVICE_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SERVICE_ADAPTER_DIR/../../core/common.sh"
source "$SERVICE_ADAPTER_DIR/provision.sh"

service_validate_configuration() { load_infra_config; }
service_is_available() { require_container infra-postgres; }
service_health() {
    service_is_available
    docker exec infra-postgres pg_isready -U infra_admin -d postgres >/dev/null
}
service_backup_available() { require_container infra-postgres; }
service_provision() { create_postgres; }
service_remove() { remove_postgres; }
service_generate_connection_config() { return 0; }
