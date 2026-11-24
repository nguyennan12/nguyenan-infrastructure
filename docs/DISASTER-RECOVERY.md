# Disaster recovery

## Recovery prerequisites (store outside VPS)

Google account access; original Google OAuth client ID and secret; protected Rclone configuration or ability to reauthorize the same OAuth application; Restic password; private Git repository access; DNS and cloud account access. With `drive.file`, a different OAuth application may not see the original backup objects. Do not rely on a credential that exists only inside the encrypted backup.

Repository: `rclone:gdrive-backup:infra-backup-v2` (or your configured backup bucket).

## Backup schedule

Daily 02:00 local time: PostgreSQL SQL dump, Redis RDB and ACL, MinIO objects and metadata, infrastructure config. Sunday 05:00: integrity check, retention and prune. Keep 7 daily, 4 weekly and 3 monthly snapshots per host/path/tag group. These are sequential snapshots, not a transactionally consistent cross-service point in time. MinIO mirror covers current objects, not full version history. Check Drive quota and trash usage; no guarantee that pruning immediately frees quota.

## Inspect and restore files

On a recovery machine, install Restic and Rclone, reconstruct the protected config and password file, then set `RESTIC_REPOSITORY`, `RCLONE_CONFIG`, `RESTIC_PASSWORD_FILE` as in the backup environment. Do not run `restic init` on the existing repository.

```bash
restic -o rclone.timeout=5m snapshots
restic -o rclone.timeout=5m check --read-data
umask 077
mkdir -p ./recovery
for tag in postgresql redis minio infrastructure; do
  restic -o rclone.timeout=5m restore latest --tag "$tag" --target "./recovery/$tag" || exit 1
done
```

Use explicit snapshot IDs instead of latest when recovering to a chosen time. Restored files are plaintext and contain secrets; restrict access and remove test copies after validation.

## Restore services on a separate host

1. Use the repository and recovered Dockhand archive to reconstruct deployment settings. Docker inspect JSON is reference metadata, not an executable Compose replacement. Review absolute bind paths, images, networks, volumes and secrets. Restore Dockhand data only while Dockhand is stopped. Restore Traefik dynamic configuration and certificate volume with proper permissions, or obtain fresh certificates.
   - **Infrastructure domain restoration**: `scripts/restore-infra.sh` handles `/opt/infra/infrastructure.env`. If the destination VPS already has `/opt/infra/infrastructure.env` configured (e.g., targeting a new recovery domain), it is preserved. If not present on the host, it is restored from the backup with permissions `600` (root:root). When restoring from an older backup snapshot without `infrastructure.env`, create `/opt/infra/infrastructure.env` manually (`INFRA_DOMAIN=example.com`).
   - In Dockhand, verify `INFRA_DOMAIN` matches the target domain for `infra-database`, `infra-cache`, and `infra-storage`.
   - Update DNS records for `postgres`, `redis`, and `minio` subdomains to point to the recovery VPS IP.
2. PostgreSQL: restore the SQL dump into a fresh compatible test cluster, not the live cluster. The dump contains global roles and database creation statements. Use a distinct bootstrap superuser to avoid duplicate-role conflicts, inspect the existing `postgres` database statements and resolve conflicts before restoring. Execute with `psql -X -v ON_ERROR_STOP=1`, verify all databases, roles, ownership, row counts and PgBouncer auth. Do not reapply setup-auth.sql if restored already.
3. Redis: recover `redis.rdb` and `users.acl` into the intended data volume while stopped. For a fresh recovery volume start with AOF disabled so Redis loads RDB, validate keys/ACLs, then enable AOF and verify rewrite completion before restoring the normal AOF-enabled Compose configuration. Do not leave stale AOF files that override the restored RDB. Restore correct Redis ownership/permissions and admin backup secret.
4. MinIO: deploy compatible MinIO with recovered root credentials. Recreate buckets, import bucket/IAM metadata with matching `mc admin cluster ... import` commands (check version-specific help), restore server configuration selectively, mirror objects into the correct buckets and verify application IAM. Empty buckets, version history, object metadata and service-account recovery require explicit validation.
5. Redeploy remaining services, verify permissions and TLS, configure SSH tunnels and NSG. Cut over DNS only after testing. Reenable backups with original credentials; check new snapshots and schedule.

## Validation status

PostgreSQL backup file restored and SHA-256 matched; all four backup groups were restored as files. Full application-level recovery on an independent machine has not yet been demonstrated. Test that before relying on the runbook. On a daily schedule, potential data loss can exceed 24 hours if a scheduled backup fails; recovery time is not yet measured.

## Operational checks

```bash
sudo tail -n 50 /opt/infra/backup/backup.log
sudo tail -n 50 /opt/infra/backup/maintenance.log
sudo crontab -l
```

Review every service result, snapshot age and available Google Drive capacity. Keep a separately protected offline copy where possible.

## Backup and restore script inventory

| Script | Responsibility |
|---|---|
| backup-all.sh | Run backup components sequentially, aggregate failures |
| backup-postgres.sh | pg_dumpall, including roles and databases |
| backup-redis.sh | RDB, redis-check-rdb, persistent users.acl |
| backup-minio.sh | Current objects, bucket/IAM metadata, configuration reference |
| backup-infra.sh | Docker metadata, Dockhand and ACME archives, configs, project metadata and protected backup configuration |
| maintenance.sh | Integrity check, retention and prune |
| restore-all.sh / restore-infra.sh | Recover selected snapshots/config and empty volumes on a separate host |
| restore-postgres.sh / restore-redis.sh / restore-minio.sh | Service-specific restore steps; inspect actual script arguments first |

Backup scripts run from `/opt/infra/backup`; management/restore scripts are installed under `/opt/infra/scripts`. Source host is `vps-nguyenan`. Snapshot tags: `postgresql`, `redis`, `minio`, `infrastructure`. Restore related snapshots from the same intended backup run, not blindly the latest per tag. Infrastructure backup includes sensitive Docker inspect output, backup credentials and `/opt/infra/projects`; Dockhand may briefly stop during backup. Restore only into empty intended volumes; isolate recovered Dockhand before starting so it cannot auto-deploy unexpectedly. The restored cron configuration must be reviewed before enabling jobs.

On the current host, inspect the repository without printing credentials:

```bash
sudo bash -c 'set -a; . /opt/infra/backup/.env; set +a; restic snapshots'
sudo tail -n 60 /opt/infra/backup/backup.log
```

The Redis cleanup error was fixed and a successful snapshot `42b795b9` was reported. A saved snapshot alone is not proof of a successful entire backup run; check the aggregate exit status and all four groups. Full service recovery remains untested. Target daily RPO is approximately 24 hours only when every scheduled run succeeds; RTO unknown. Keep access credentials outside the VPS and never overwrite the original backup repository during a drill.
