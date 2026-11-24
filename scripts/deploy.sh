#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
REPO_DIR_EXPLICIT="${REPO_DIR:-}"
if [ -d "$INFRA_ROOT/repository/.git" ]; then
    DEFAULT_REPO_DIR="$INFRA_ROOT/repository"
else
    DEFAULT_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
REPO_DIR="${REPO_DIR:-$DEFAULT_REPO_DIR}"
SECRETS_DIR="$INFRA_ROOT/secrets"
STATE_DIR="$INFRA_ROOT/state"
INFRA_CONFIG_FILE="${INFRA_CONFIG_FILE:-$INFRA_ROOT/infrastructure.env}"
DEPLOYMENT_CONFIG_FILE="${DEPLOYMENT_CONFIG_FILE:-$INFRA_ROOT/deployment.env}"
CHECK_ONLY=false

[ "${1:-}" = "--check" ] && CHECK_ONLY=true

source "$SCRIPT_DIR/lib/common.sh"

if [ -z "$REPO_DIR_EXPLICIT" ]; then
    CONFIGURED_REPO="$(read_config_value "$DEPLOYMENT_CONFIG_FILE" REPOSITORY_DIR || true)"
    [ -z "$CONFIGURED_REPO" ] || REPO_DIR="$CONFIGURED_REPO"
fi

if [ "$EUID" -ne 0 ] && [ "${INFRA_TEST_MODE:-0}" != "1" ]; then
    echo "Please run with sudo."
    exit 1
fi

require_value() {
    local file="$1"
    local key="$2"
    local value

    value="$(read_config_value "$file" "$key" || true)"
    if [ -z "$value" ]; then
        echo "Missing $key in $file" >&2
        return 1
    fi
}

load_deployment_config
if [ "$DEPLOYMENT_MODE" != "standalone" ]; then
    echo "Standalone deployment requires DEPLOYMENT_MODE=standalone." >&2
    exit 1
fi

load_infra_config

require_value "$SECRETS_DIR/gateway.env" ACME_EMAIL
require_value "$SECRETS_DIR/database.env" POSTGRES_PASSWORD
require_value "$SECRETS_DIR/database.env" PGBOUNCER_AUTH_PASSWORD
require_value "$SECRETS_DIR/cache.env" REDIS_PASSWORD
require_value "$SECRETS_DIR/storage.env" MINIO_ROOT_USER
require_value "$SECRETS_DIR/storage.env" MINIO_ROOT_PASSWORD

if [ "$(stat -c '%a' "$SECRETS_DIR")" != "700" ] ||
   { [ "$(stat -c '%u' "$SECRETS_DIR")" != "0" ] &&
     [ "${INFRA_TEST_MODE:-0}" != "1" ]; }; then
    echo "Secret directory must be root-owned with mode 700: $SECRETS_DIR" >&2
    exit 1
fi

for file in gateway database cache storage; do
    if [ "$(stat -c '%a' "$SECRETS_DIR/$file.env")" != "600" ]; then
        echo "Secret file must have mode 600: $SECRETS_DIR/$file.env" >&2
        exit 1
    fi
    if [ "$(stat -c '%u' "$SECRETS_DIR/$file.env")" != "0" ] &&
       [ "${INFRA_TEST_MODE:-0}" != "1" ]; then
        echo "Secret file must be root-owned: $SECRETS_DIR/$file.env" >&2
        exit 1
    fi
done

if $CHECK_ONLY; then
    echo "Standalone configuration is valid."
    exit 0
fi

command -v docker >/dev/null
docker compose version >/dev/null

if docker container inspect dockhand >/dev/null 2>&1; then
    echo "Dockhand was detected. Standalone deployment ownership migration is not automatic." >&2
    exit 1
fi

install -d -m 700 "$STATE_DIR"
OWNER_FILE="$STATE_DIR/deployment-owner"
if [ -f "$OWNER_FILE" ] && [ "$(cat "$OWNER_FILE")" != "standalone" ]; then
    echo "Another deployment controller owns these stacks." >&2
    exit 1
fi

if [ ! -f "$OWNER_FILE" ]; then
    if [ ! -f "$STATE_DIR/restore-prepared" ]; then
        for container in infra-traefik infra-postgres infra-pgbouncer infra-redis infra-minio; do
            if docker container inspect "$container" >/dev/null 2>&1; then
                echo "Existing infrastructure container $container has no Standalone ownership record." >&2
                exit 1
            fi
        done

        for volume in \
            infra-gateway_traefik_certs \
            infra-database_postgres_data \
            infra-cache_redis_data \
            infra-storage_minio_data
        do
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                echo "Existing infrastructure volume $volume has no Standalone ownership record." >&2
                echo "Use the documented restore or ownership migration procedure; automatic adoption is disabled." >&2
                exit 1
            fi
        done
    fi
fi

if ! docker network inspect proxy >/dev/null 2>&1; then
    echo "Expected external Docker network 'proxy' does not exist." >&2
    exit 1
fi

test -s "$INFRA_ROOT/traefik/dynamic/tls.yml"

if [ "${INFRA_DEPLOY_LOCK_HELD:-0}" != "1" ]; then
    exec 9>"$STATE_DIR/deployment.lock"
    flock -n 9 || {
        echo "Another deployment is running." >&2
        exit 1
    }
fi

if [ "${INFRA_OPERATION_LOCKS_HELD:-0}" != "1" ]; then
    install -d -m 700 "$INFRA_ROOT/backup"
    exec 8>"$INFRA_ROOT/backup/backup.lock"
    exec 7>"$STATE_DIR/provisioning.lock"
    exec 6>"$STATE_DIR/restore.lock"
    flock -n 8 && flock -n 7 && flock -n 6 || {
        echo "A backup, restore or project operation is running." >&2
        exit 1
    }
fi

compose() {
    local project="$1"
    local stack="$2"
    local secret_file="$3"
    shift 3

    docker compose \
        --project-name "$project" \
        --env-file "$INFRA_CONFIG_FILE" \
        --env-file "$SECRETS_DIR/$secret_file" \
        --file "$REPO_DIR/stacks/$stack.yml" \
        "$@"
}

echo "Validating Compose stacks..."
compose infra-gateway gateway gateway.env config --quiet
compose infra-database database database.env config --quiet
compose infra-cache cache cache.env config --quiet
compose infra-storage storage storage.env config --quiet

DEPLOY_REVISION="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'deploying %s\n' "$DEPLOY_REVISION" > "$STATE_DIR/deployment-status"
deployment_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'failed %s\n' "$DEPLOY_REVISION" > "$STATE_DIR/deployment-status"
        echo "Deployment failed after validation. Existing volumes were preserved; inspect container state before retrying." >&2
    fi
}
trap deployment_exit EXIT

printf '%s\n' standalone > "$OWNER_FILE"
chmod 600 "$OWNER_FILE"

wait_running() {
    local container="$1"
    local attempt
    for attempt in $(seq 1 60); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = "true" ]; then
            return 0
        fi
        sleep 2
    done
    echo "Container did not become ready: $container" >&2
    return 1
}

wait_postgres() {
    local attempt
    for attempt in $(seq 1 60); do
        if docker exec infra-postgres pg_isready -U infra_admin -d postgres >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "PostgreSQL readiness check failed." >&2
    return 1
}

initialize_redis_acl() {
    local password
    local password_hash
    local volume="infra-cache_redis_data"

    password="$(read_config_value "$SECRETS_DIR/cache.env" REDIS_PASSWORD)"
    password_hash="$(printf '%s' "$password" | sha256sum | awk '{print $1}')"

    docker volume create "$volume" >/dev/null
    if docker run --rm -v "$volume:/data" --entrypoint sh redis:8-alpine -ec 'test -s /data/users.acl'; then
        return 0
    fi

    if ! docker run --rm -v "$volume:/data" --entrypoint sh redis:8-alpine -ec 'test -z "$(ls -A /data)"'; then
        echo "Redis volume is non-empty but users.acl is missing; refusing initialization." >&2
        return 1
    fi

    printf 'user default on #%s ~* &* +@all\n' "$password_hash" |
        docker run --rm -i -v "$volume:/data" --entrypoint sh redis:8-alpine -ec '
            umask 077
            cat > /data/users.acl
            chown redis:redis /data/users.acl
        '
}

echo "Deploying gateway..."
compose infra-gateway gateway gateway.env up -d
wait_running infra-traefik

echo "Deploying PostgreSQL..."
compose infra-database database database.env up -d postgres
wait_postgres

if [ "$(docker exec infra-postgres psql -X -At -U infra_admin -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname='pgbouncer_auth';")" = "0" ]; then
    echo "Initializing PgBouncer authentication..."
    docker exec -i infra-postgres psql -X -v ON_ERROR_STOP=1 -U infra_admin -d postgres \
        < "$REPO_DIR/configs/pgbouncer/setup-auth.sql"
    PGBOUNCER_PASSWORD="$(read_config_value "$SECRETS_DIR/database.env" PGBOUNCER_AUTH_PASSWORD)"
    printf "ALTER ROLE pgbouncer_auth PASSWORD '%s';\n" "$PGBOUNCER_PASSWORD" |
        docker exec -i infra-postgres psql -X -v ON_ERROR_STOP=1 -U infra_admin -d postgres >/dev/null
    unset PGBOUNCER_PASSWORD
fi

PGBOUNCER_PASSWORD="$(read_config_value "$SECRETS_DIR/database.env" PGBOUNCER_AUTH_PASSWORD)"
docker exec -e PGPASSWORD="$PGBOUNCER_PASSWORD" infra-postgres \
    psql -X -h 127.0.0.1 -U pgbouncer_auth -d postgres -Atc 'SELECT 1' >/dev/null || {
        echo "PgBouncer authentication role does not match the configured credential; refusing automatic rotation." >&2
        exit 1
    }
unset PGBOUNCER_PASSWORD

compose infra-database database database.env up -d
wait_running infra-pgbouncer
docker exec infra-pgbouncer pg_isready -h 127.0.0.1 -p 6432 >/dev/null

echo "Initializing and deploying Redis..."
initialize_redis_acl
compose infra-cache cache cache.env up -d
wait_running infra-redis
REDIS_ADMIN_PASSWORD="$(read_config_value "$SECRETS_DIR/cache.env" REDIS_PASSWORD)"
test "$(docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASSWORD" infra-redis redis-cli --raw PING)" = "PONG"
unset REDIS_ADMIN_PASSWORD

echo "Deploying MinIO..."
compose infra-storage storage storage.env up -d
wait_running infra-minio
docker exec infra-minio sh -ec '
    MC_CONFIG_DIR="$(mktemp -d)"
    export MC_CONFIG_DIR
    trap "rm -rf \"$MC_CONFIG_DIR\"" EXIT
    mc alias set verify http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    mc admin info verify >/dev/null
'

if [ "$DEPLOY_REVISION" != "unknown" ]; then
    printf '%s\n' "$DEPLOY_REVISION" > "$STATE_DIR/last-deployed-commit"
fi

printf 'deployed %s\n' "$DEPLOY_REVISION" > "$STATE_DIR/deployment-status"

rm -f -- "$STATE_DIR/restore-prepared"
trap - EXIT

echo "Standalone infrastructure deployment completed successfully."
