#!/usr/bin/env bash

SERVICE_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SERVICE_ADAPTER_DIR/../../core/common.sh"
source "$SERVICE_ADAPTER_DIR/provision.sh"

service_validate_configuration() { load_infra_config; test -s "$INFRA_ROOT/backup/.redis-password"; }
service_is_available() { require_container infra-redis; }
service_health() {
    local password
    service_validate_configuration
    service_is_available
    password="$(cat "$INFRA_ROOT/backup/.redis-password")"
    test "$(docker exec -e REDISCLI_AUTH="$password" infra-redis redis-cli --raw PING)" = "PONG"
}
service_backup_available() { require_container infra-redis; }
service_provision() { create_redis; }
service_remove() { remove_redis; }
service_generate_connection_config() { return 0; }
