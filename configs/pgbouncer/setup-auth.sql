-- PgBouncer Dynamic Authentication
-- Execute as infra_admin in the postgres database.

BEGIN;

-- Create authentication role
CREATE ROLE pgbouncer_auth WITH
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;

GRANT CONNECT ON DATABASE postgres TO pgbouncer_auth;

-- Create authentication schema
CREATE SCHEMA IF NOT EXISTS pgbouncer;

REVOKE ALL ON SCHEMA pgbouncer FROM PUBLIC;

-- Create authentication function
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_username TEXT)
RETURNS TABLE(username TEXT, password TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT rolname::TEXT,
        CASE
            WHEN rolvaliduntil < now() THEN NULL
            ELSE rolpassword::TEXT
        END
    FROM pg_catalog.pg_authid
    WHERE rolname = p_username
      AND rolcanlogin
      AND NOT rolsuper
      AND rolname <> 'pgbouncer_auth';
$$;

-- Restrict authentication permissions
REVOKE ALL ON FUNCTION pgbouncer.get_auth(TEXT)
FROM PUBLIC;

GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;

GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT)
TO pgbouncer_auth;

COMMIT;