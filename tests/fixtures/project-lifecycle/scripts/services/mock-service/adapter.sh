#!/usr/bin/env bash
SERVICE_ID="$(basename "$(dirname "${BASH_SOURCE[0]}")")"
service_validate_configuration() { return 0; }
service_is_available() { [ "${MOCK_UNAVAILABLE_SERVICE:-}" != "$SERVICE_ID" ]; }
service_health() { service_is_available; }
service_provision() { set_service_state "$SERVICE_ID" true; printf 'provision:%s\n' "$SERVICE_ID" >> "$MOCK_HOOK_LOG"; }
service_remove() { set_service_state "$SERVICE_ID" false; printf 'remove:%s\n' "$SERVICE_ID" >> "$MOCK_HOOK_LOG"; }
service_generate_connection_config() { return 0; }
