# Disaster recovery

## Recovery prerequisites (store outside VPS)

Google account access; original Google OAuth client ID and secret; protected Rclone configuration or ability to reauthorize the same OAuth application; Restic password; private Git repository access; DNS and cloud account access. With `drive.file`, a different OAuth application may not see the original backup objects. Do not rely on a credential that exists only inside the encrypted backup.

Repository: `rclone:gdrive-backup:static4j-backup-v2` (initial repository ID prefix `0bfefca8`).

## Backup schedule

Daily 02:00 local time: PostgreSQL SQL dump, Redis RDB and ACL (verify ACL is included), MinIO objects and metadata, infrastructure config. Sunday 05:00: integrity check, retention and prune. Keep 7 daily, 4 weekly and 3 monthly snapshots per host/path/tag group. These are sequential snapshots, not a transactionally consistent cross-service point in time. MinIO mirror covers current objects, not full version history. Check Drive quota and trash usage; no guarantee that pruning immediately frees quota.

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
