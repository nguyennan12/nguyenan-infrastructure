# Create a project

Example project: VitaFlix. Repeat with unique credentials and names for each project.

## PostgreSQL

In pgAdmin via SSH tunnel, create Login/Group Role `vitaflix_user` with Login enabled and no superuser/create role/create DB privileges. Set a strong password. Create `vitaflix_db` owned by this role. From the postgres database Query Tool:

```sql
REVOKE CONNECT ON DATABASE vitaflix_db FROM PUBLIC;
GRANT CONNECT ON DATABASE vitaflix_db TO vitaflix_user;
```

Apply equivalent restrictions to other project databases. Review access to administrative/default databases separately. Verify PgBouncer dynamic auth and connect using the project role, not infra_admin. Transaction pooling may require ORM/driver-specific configuration; use a direct private connection for migrations that need session semantics.

## Redis

Connect as default administrator via RedisInsight Workbench or redis-cli. Generate a strong password and replace the placeholder below (do not save the actual password in Git).

```redis
ACL SETUSER vitaflix_user reset on >REPLACE_WITH_STRONG_PASSWORD ~vitaflix:* +get +set +del +unlink +exists +expire +pexpire +ttl +pttl +mget +mset +incr +decr +ping +hello +select +client|setinfo
ACL SAVE
```

Use `reset` only when intentionally creating/replacing the entire ACL definition. For password rotation use `resetpass` instead. Test GET/SET under `vitaflix:*` and verify other namespaces are denied. Adjust the explicit command allowlist to application needs; do not grant broad admin access. Ensure clients apply the prefix themselves. Verify ACL is backed up.

## MinIO

Via the private Console create bucket `vitaflix`, private access, versioning off for the current backup design. Create a policy `vitaflix-policy` that allows bucket location/list/multipart listing on `arn:aws:s3:::vitaflix`, and GetObject/PutObject/DeleteObject/AbortMultipartUpload/ListMultipartUploadParts on `arn:aws:s3:::vitaflix/*`. Create `vitaflix_user` with a strong unique secret and attach only this policy. Test upload/download/delete on the intended bucket and denied access elsewhere.

## Backend environment example

```dotenv
DATABASE_URL=postgresql://vitaflix_user:REPLACE_ME@postgres.static4j.app:6433/vitaflix_db?sslmode=verify-full
REDIS_URL=rediss://vitaflix_user:REPLACE_ME@redis.static4j.app:6380
REDIS_KEY_PREFIX=vitaflix:
S3_ENDPOINT=https://minio.static4j.app
S3_BUCKET=vitaflix
S3_ACCESS_KEY=vitaflix_user
S3_SECRET_KEY=REPLACE_ME
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true
```

Set real values in backend secret settings. URL-encode passwords in connection URLs. Configure trusted CA and hostname verification according to the actual driver; do not disable certificate verification. Environment variable names and prefix settings must be supported by your application. Never expose these credentials to frontend code.

## Acceptance

Verify connection from backend host; successful database query and migration; Redis allowed/denied keys; MinIO allowed/denied operations; backup after provisioning. Add backend egress IPs to NSG if required. Confirm resource usage under load.
