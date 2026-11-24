# Deployment

This is a bootstrap runbook, not a tested one-command installer. Review the actual Compose files and image versions before execution. For recovery of an existing installation, read DISASTER-RECOVERY.md first.

## Prerequisites

- Ubuntu 24.04 VPS, SSH key access, Docker Engine and Compose plugin.
- DNS control for static4j.app, Azure NSG access, private Git repository access.
- A password manager, Google Drive account and dedicated Google OAuth desktop client for backup.

## Bootstrap

1. Install Docker using the official Ubuntu instructions and install `restic`, `rclone`, `cron` via apt. Configure swap if necessary, and verify available RAM/disk.
2. Clone the private repository using authorized credentials. Create a local `.env` from `.env.example`, restrict permissions and populate real secrets outside Git. In Dockhand, set the equivalent variables separately for each stack.
3. Create the shared network if absent:

   ```bash
   docker network inspect proxy >/dev/null 2>&1 || docker network create proxy
   sudo install -d /opt/infra/traefik/dynamic
   sudo install -m 644 configs/traefik/dynamic/tls.yml /opt/infra/traefik/dynamic/tls.yml
   ```
4. Point the DNS A records `postgres`, `redis`, `minio` to the new VPS IP. Configure NSG as in SECURITY.md. For migration, defer production DNS cutover until validation; ACME HTTP challenge requires reachable port 80 and matching DNS.
5. Deploy gateway, then database, cache and storage. Keep Compose project names `infra-gateway`, `infra-database`, `infra-cache`, `infra-storage` unchanged to preserve named-volume mapping. Inspect `docker compose config` locally (it can reveal secrets; do not share output).

## Database bootstrap (fresh install only)

Start PostgreSQL before PgBouncer. For CLI deployments from repository root:

```bash
docker compose --env-file .env -p infra-database -f stacks/database.yml up -d postgres
docker exec -i infra-postgres psql -v ON_ERROR_STOP=1 -U infra_admin -d postgres < configs/pgbouncer/setup-auth.sql
docker exec -it infra-postgres psql -U infra_admin -d postgres
```

In psql run `\password pgbouncer_auth` and enter the same secret as `PGBOUNCER_AUTH_PASSWORD`, then `\q`. Deploy PgBouncer. Do not rerun bootstrap against a restored cluster that already contains the role/function. Verify `auth_dbname=postgres` and the intended `auth_query` in generated config.

## Redis bootstrap (fresh install only)

The cache stack expects `/data/users.acl` before starting Redis. Create the named volume defined by the actual Compose file, then create `users.acl` with an enabled default admin, a SHA-256 hash of a strong password, `~* &* +@all`, restrictive permissions and ownership matching the Redis runtime user. Alternatively temporarily start Redis with `--requirepass`, export `ACL LIST` to the volume, then switch to `--aclfile /data/users.acl`. Never overwrite an existing ACL file during recovery. Keep backup password and healthcheck consistent with the admin credential. Run `ACL SAVE` after changes.

## Backup bootstrap

Install reviewed scripts to `/opt/infra/backup` (root-owned, mode 700). Create staging directory and restricted `.env`, `.redis-password`, `rclone.conf`, `.restic-password`. Configure Rclone with the dedicated OAuth client and `drive.file` scope. For an existing repository use the original OAuth application and Restic password; never initialize over an existing repository. See recovery guide.

```bash
sudo timedatectl set-timezone Asia/Ho_Chi_Minh
sudo systemctl enable --now cron
sudo crontab -e
```

```cron
0 2 * * * /opt/infra/backup/backup-all.sh >> /opt/infra/backup/backup.log 2>&1
0 5 * * 0 /opt/infra/backup/maintenance.sh >> /opt/infra/backup/maintenance.log 2>&1
```

Verify scripts, logging, volume names and backup lock before enabling the schedule. Use a single schedule for each task.

## Validation

Check `docker ps`, `docker stats --no-stream`, `free -h`, `vmstat 1 5`, `df -h`. Verify PostgreSQL query through PgBouncer with a project role, Redis TLS PING and namespace restrictions, MinIO HTTPS and project IAM, backup snapshots and restore. Confirm firewall from a permitted and a non-permitted source. Do not mark deployment complete until these tests pass.
