#!/usr/bin/env bash

redis_admin() {
    local password

    password="$(cat /opt/infra/backup/.redis-password)"

    docker exec -i \
        -e REDISCLI_AUTH="$password" \
        infra-redis redis-cli --raw "$@"
}

create_redis() {
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
REDIS_HOST=redis.static4j.app
REDIS_PORT=6380
REDIS_USER=$REDIS_USER
REDIS_PASSWORD=$password
REDIS_KEY_PREFIX=$PROJECT:
REDIS_URL=rediss://$REDIS_USER:$password@redis.static4j.app:6380
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