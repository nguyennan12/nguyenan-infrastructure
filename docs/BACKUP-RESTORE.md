# Backup and Restore

[Quick Start](QUICKSTART.md) · [Configuration](CONFIGURATION.md) · [Full recovery runbook](DISASTER-RECOVERY.md)

Restic encrypts snapshots in an Rclone-backed repository (Google Drive is supported). `/opt/infra/backup/backup-all.sh` runs enabled registered service backups in order and then infrastructure backup. Current groups cover PostgreSQL roles/databases, Redis RDB and ACL, current MinIO objects and IAM metadata, and infrastructure configuration. These snapshots are sequential, not one cross-service transaction. MinIO object version history is not guaranteed by the current mirror.

For a fresh backup setup, `sudo /opt/infra/scripts/setup-backup.sh --fresh` offers Rclone interactive configuration or an existing `rclone.conf`, remote and repository URL, and a confirmed or generated Restic password. It initializes a new repository only after the exact `INITIALIZE` confirmation when appropriate. Store the password, Rclone/OAuth recovery material and repository URL outside the VPS before enabling scheduling. For an **existing** repository on a recovery host use `--restore`; it verifies access and lists snapshots without initializing, replacing credentials or enabling cron. `verify` checks the configured repository.

After fresh setup succeeds, `sudo /opt/infra/scripts/setup-cron.sh` installs `/etc/cron.d/infra-backup` unless it finds an existing matching schedule. Its schedule uses host local time: daily full backup at 02:00 and Sunday maintenance at 05:00. Maintenance runs Restic check, retention (`7` daily, `4` weekly, `3` monthly per host/paths/tags) and prune. It shares the backup lock. Do not run competing backup or destructive provisioning jobs manually. The aggregate command writes `/opt/infra/state/backup-status` atomically with last attempt, last complete success, result and completion timestamp. A partial backup is a failure; lock contention does not mark a new attempt failed.

Read-only checks:

```bash
sudo cat /opt/infra/state/backup-status
sudo tail -n 50 /opt/infra/backup/backup.log
sudo crontab -l
sudo cat /etc/cron.d/infra-backup
```

Restore selection must use matching snapshot IDs from the intended backup run; blindly choosing `latest` for each tag may combine incompatible points in time. The [disaster recovery runbook](DISASTER-RECOVERY.md) covers file-level inspection, order of service preparation and the `restore-all.sh`/`restore-infra.sh` workflow. **Restore commands can create volumes and replace data; use only an isolated recovery VPS and review each target first.** Existing Phase 2/3 snapshots remain supported where their tags and required credentials are available. Infrastructure backup may contain secrets and is encrypted in Restic.

Backup creation and file-level restoration have been tested in production. Complete disaster recovery on an independent clean host has not been verified (Phase 4.5 deferred). At a daily cadence, data loss may exceed 24 hours after a failed scheduled run; recovery time is unmeasured. No zero-loss or recovery-time guarantee is provided.
