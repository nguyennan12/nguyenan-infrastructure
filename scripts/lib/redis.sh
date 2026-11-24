#!/usr/bin/env bash

redis_admin() {
    local password

    password="$(cat /opt/infra/backup/.redis-password)"

    docker exec -i \
        -e REDISCLI_AUTH="$password" \
        infra-redis redis-cli --raw "$@"
}

create_redis() {
    load_infra_config
    require_container infra-redis

    echo "Creating Redis resources..."

    local password
    local users
    local result

    test "$(redis_admin PING)" = "PONG"

    users="$(redis_admin ACL USERS)"

    if grep -Fxq "$REDIS_USER" <<< "$users"; then
        echo "Redis user already exists."
        return 1
    fi

    password="$(generate_password)"

    cat >> "$ENV_FILE" <<EOF

# Redis
REDIS_HOST=$REDIS_HOST
REDIS_PORT=6380
REDIS_USER=$REDIS_USER
REDIS_PASSWORD=$password
REDIS_KEY_PREFIX=$PROJECT:
REDIS_URL=rediss://$REDIS_USER:$password@$REDIS_HOST:6380
EOF

    result="$(redis_admin ACL SETUSER "$REDIS_USER" \
        reset on ">$password" \
        "~$PROJECT:*" \
        +ping +get +set +del +unlink \
        +exists +expire +pexpire +ttl +pttl \
        +mget +mset +incr +decr \
        +hget +hset +hdel +hgetall)"

    test "$result" = "OK"
    test "$(redis_admin ACL SAVE)" = "OK"

    set_service_state redis true

    echo "Redis provisioned successfully."
}

remove_redis() {
    require_container infra-redis

    echo "Removing Redis resources..."

    test "$(redis_admin PING)" = "PONG"

    # Disable access and disconnect existing clients
    test "$(redis_admin ACL SETUSER "$REDIS_USER" off)" = "OK"

    redis_admin CLIENT KILL USER "$REDIS_USER"

    test "$(redis_admin ACL SAVE)" = "OK"

    # Delete matching keys in bounded batches.
    # Lua preserves keys containing special characters.
    local cursor=0
    local result

    while true; do
        result="$(redis_admin EVAL '
            local result = redis.call(
                "SCAN", ARGV[1],
                "MATCH", ARGV[2],
                "COUNT", 100
            )

            for _, key in ipairs(result[2]) do
                redis.call("UNLINK", key)
            end

            return result[1]
        ' 0 "$cursor" "$PROJECT:*")"

        if [[ ! "$result" =~ ^[0-9]+$ ]]; then
            echo "Redis cleanup failed."
            return 1
        fi

        cursor="$result"

        [ "$cursor" != "0" ] || break
    done

    if [ -n "$(redis_admin --scan --pattern "$PROJECT:*")" ]; then
        echo "Redis keys remain. Review manually."
        return 1
    fi

    redis_admin ACL DELUSER "$REDIS_USER"

    test "$(redis_admin ACL SAVE)" = "OK"

    remove_env_vars '^REDIS_.*$'

    set_service_state redis false

    echo "Redis removed successfully."
}