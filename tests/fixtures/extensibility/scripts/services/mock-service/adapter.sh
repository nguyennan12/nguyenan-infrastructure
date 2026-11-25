#!/usr/bin/env bash

service_validate_configuration() { return 0; }
service_is_available() { return 0; }
service_health() { return 0; }
service_backup_available() { return 0; }
service_provision() { set_service_state mock-service true; printf 'mock provision\n' >> "$MOCK_HOOK_LOG"; }
service_remove() { set_service_state mock-service false; printf 'mock remove\n' >> "$MOCK_HOOK_LOG"; }
service_generate_connection_config() { return 0; }
