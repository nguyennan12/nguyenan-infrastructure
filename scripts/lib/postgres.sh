#!/usr/bin/env bash

pg_admin() {
    docker exec -i infra-postgres \
        psql -X -v ON_ERROR_STOP=1 \
        -U infra_admin -d postgres "$@"
}

create_postgres() {
    require_container infra-postgres

    echo "Creating PostgreSQL resources..."

    local db_exists
    local role_exists
    local password

    db_exists="$(pg_admin -Atc "
        SELECT count(*) FROM pg_database
        WHERE datname = '$DB_NAME';
    ")"

    role_exists="$(pg_admin -Atc "
        SELECT count(*) FROM pg_roles
        WHERE rolname = '$DB_USER';
    ")"

    if [ "$db_exists" != "0" ] ||
       [ "$role_exists" != "0" ]; then

        echo "PostgreSQL resources already exist."
        return 1
    fi

    password="$(generate_password)"

    cat >> "$ENV_FILE" <<EOF

# PostgreSQL
POSTGRES_HOST=postgres.static4j.app
POSTGRES_PORT=6433
POSTGRES_DB=$DB_NAME
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$password
DATABASE_URL=postgresql://$DB_USER:$password@postgres.static4j.app:6433/$DB_NAME?sslmode=verify-full
EOF

    pg_admin <<SQL
CREATE ROLE "$DB_USER"
    LOGIN
    PASSWORD '$password'
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;

CREATE DATABASE "$DB_NAME"
    OWNER "$DB_USER";

REVOKE CONNECT ON DATABASE "$DB_NAME" FROM PUBLIC;

GRANT CONNECT ON DATABASE "$DB_NAME" TO "$DB_USER";
SQL

    set_service_state postgres true

    echo "PostgreSQL provisioned successfully."
}

remove_postgres() {
    require_container infra-postgres

    echo "Removing PostgreSQL resources..."

    pg_admin -c "ALTER ROLE \"$DB_USER\" NOLOGIN;"

    pg_admin -c "
        DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);
    "

    pg_admin -c "
        DROP ROLE IF EXISTS \"$DB_USER\";
    "

    remove_env_vars '^(POSTGRES_.*|DATABASE_URL)$'

    set_service_state postgres false

    echo "PostgreSQL removed successfully."
}remove_postgres() {
    require_container infra-postgres

    echo "Removing PostgreSQL resources..."

    pg_admin -c "ALTER ROLE \"$DB_USER\" NOLOGIN;"

    pg_admin -c "
        DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);
    "

    pg_admin -c "
        DROP ROLE IF EXISTS \"$DB_USER\";
    "

    remove_env_vars '^(POSTGRES_.*|DATABASE_URL)$'

    set_service_state postgres false

    echo "PostgreSQL removed successfully."
}