# Modular project lifecycle

Modular provisioning is the default for all managed projects. Legacy migration is intentionally omitted. Run commands on the VPS via SSH as an authorized administrator.

## Create and inspect

```bash
sudo /opt/infra/scripts/create-project.sh myapp --postgres --redis
sudo /opt/infra/scripts/create-project.sh myapp --services postgres,redis
sudo /opt/infra/scripts/list-projects.sh
sudo /opt/infra/scripts/list-services.sh
```

Use `--services id1,id2`, the compatible `--postgres`, `--redis`, `--minio` flags, or `--all`; omit flags for registry-driven interactive selection. `--all` means every enabled, available project capability, not every possible infrastructure stack. `list-services.sh` distinguishes registered, enabled, currently available, deployed and healthy states. Enter `CREATE myapp` when prompted. Names use lowercase letters/digits, start with a letter, 3–30 characters. MinIO operations request administrator credentials interactively.
Service endpoints are automatically derived from `/opt/infra/infrastructure.env` (`POSTGRES_HOST=postgres.${INFRA_DOMAIN}`, `REDIS_HOST=redis.${INFRA_DOMAIN}`, `S3_ENDPOINT=https://minio.${INFRA_DOMAIN}`).
Credentials are generated and saved in the protected `/opt/infra/projects/myapp/.env`; do not share or commit this file. The manifest `project.json` records dynamic service flags and lifecycle status. The reader still accepts existing manifests containing the original three booleans. Project listing reads metadata, while service listing performs infrastructure availability and health checks.

| Service | Resource names | Isolation |
|---|---|---|
| PostgreSQL | myapp_db, myapp_user | Database ownership, CONNECT restrictions |
| Redis | myapp_user, myapp:* | ACL key prefix and command allowlist |
| MinIO | myapp, myapp_user, myapp-policy | Private bucket and scoped IAM |

## Add, remove, delete

```bash
sudo /opt/infra/scripts/add-service.sh myapp --minio
sudo /opt/infra/scripts/remove-service.sh myapp --redis
sudo /opt/infra/scripts/delete-project.sh myapp
```

These are separate operations; run only the intended command. Confirm with `ADD myapp`, `REMOVE myapp` or `DELETE myapp`. Remove/delete are destructive: stop dependent applications, verify a successful backup and review scope first. Remove deletes only selected services, including their data. Delete removes all enabled services and metadata. MinIO deletion disables then removes the user, removes the bucket and policy; policy detach was removed after a failed test. Automatic deletion after this fix has not been retested.

## Failure handling

A failure can leave `incomplete` metadata and partially created/deleted resources. Do not blindly retry or set all flags false; do not delete the project directory first. Inspect `project.json`, logs and actual service resources; verify backups. Coordinate with provisioning/sync locks. Repair only the affected resources, update metadata only after verification, and preserve unrelated applications. The current scripts do not provide automatic resume/rollback for incomplete projects. The prior modulartest MinIO cleanup was manual.

## Backend environment example

```dotenv
DATABASE_URL=postgresql://myapp_user:REPLACE_ME@postgres.example.com:6433/myapp_db?sslmode=verify-full
REDIS_URL=rediss://myapp_user:REPLACE_ME@redis.example.com:6380
REDIS_KEY_PREFIX=myapp:
S3_ENDPOINT=https://minio.example.com
S3_BUCKET=myapp
S3_ACCESS_KEY=myapp_user
S3_SECRET_KEY=REPLACE_ME
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true
```

Set real values in backend secret settings. URL-encode passwords in connection URLs. Configure trusted CA and hostname verification according to the actual driver; do not disable certificate verification. Environment variable names and prefix settings must be supported by your application. Never expose these credentials to frontend code.

## Updating existing projects after domain change

When changing `INFRA_DOMAIN` in `/opt/infra/infrastructure.env`, existing projects retain their existing `.env` files to prevent unexpected service disruption. To migrate existing projects to the new domain:

1. Edit `/opt/infra/projects/<project>/.env`:
   - Update `POSTGRES_HOST=postgres.newdomain.com`
   - Update `DATABASE_URL` with `postgres.newdomain.com`
   - Update `REDIS_HOST=redis.newdomain.com`
   - Update `REDIS_URL` with `redis.newdomain.com`
   - Update `S3_ENDPOINT=https://minio.newdomain.com`
2. Update the environment variables in your external application deployment (e.g. backend service).
3. Verify connection with the new domain.

## Acceptance

Verify connection from backend host; successful database query and migration; Redis allowed/denied keys; MinIO allowed/denied operations; backup after provisioning. Add backend egress IPs to NSG if required. Confirm resource usage under load.


## Driver and isolation caveats

PgBouncer uses transaction pooling; session-dependent migrations may require a private direct PostgreSQL connection. Review CONNECT privileges on default and existing databases separately. Redis prefixing must be implemented by the application; check driver-required commands against the ACL allowlist. Redis shares memory and eviction across projects. MinIO backups cover current objects, not full version history. Use per-project accounts and verify denial of access to unrelated resources.
