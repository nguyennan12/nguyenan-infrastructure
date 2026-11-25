#!/usr/bin/env bash

SERVICE_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SERVICE_ADAPTER_DIR/../../core/common.sh"
source "$SERVICE_ADAPTER_DIR/provision.sh"

service_validate_configuration() { load_infra_config; command -v mc >/dev/null; }
service_is_available() { require_container infra-minio && command -v mc >/dev/null; }
service_health() {
    require_container infra-minio
    docker exec infra-minio sh -ec '
        MC_CONFIG_DIR="$(mktemp -d)"
        export MC_CONFIG_DIR
        trap "rm -rf \"$MC_CONFIG_DIR\"" EXIT
        mc alias set verify http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
        mc admin info verify >/dev/null
    '
}
service_backup_available() { require_container infra-minio; }
service_provision() { create_minio; }
service_remove() { remove_minio; }
service_generate_connection_config() { return 0; }
