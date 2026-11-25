# Phase 3.1 GitOps synchronizer migration

The existing `/opt/infra/bin/sync-infra.sh` must be replaced once by the stable launcher. The systemd service and timer names, `ExecStart`, schedule and Dockhand ownership stay unchanged. The launcher fetches `production`, pins one commit and executes that commit's worker. The worker stages and validates managed files, records rollback copies, installs scripts before registry metadata and advances `last-sync-commit` after verification. `sync-status` records progress. A `recovery-required` status needs manual inspection.

Only perform this after CI has promoted the reviewed commit to `production`. On the Ubuntu GitOps host, inspect `git -C /opt/infra/repository remote -v` and `systemctl status infra-sync.timer`, then run as root:

```bash
sudo systemctl stop infra-sync.timer
sudo systemctl stop infra-sync.service
sudo install -d -m 700 /opt/infra/state /opt/infra/bin
sudo flock -x /opt/infra/state/sync.lock bash -c '
  exec 8>/opt/infra/backup/backup.lock
  flock -n 8 || exit 1
  exec 7>/opt/infra/state/provisioning.lock
  flock -n 7 || exit 1
  git -C /opt/infra/repository fetch --no-tags origin production
  commit=$(git -C /opt/infra/repository rev-parse --verify "FETCH_HEAD^{commit}")
  git -C /opt/infra/repository show "$commit:scripts/deployment/sync-launcher.sh" > /opt/infra/state/sync-launcher.new
  test -s /opt/infra/state/sync-launcher.new
  bash -n /opt/infra/state/sync-launcher.new
  cp -p /opt/infra/bin/sync-infra.sh /opt/infra/state/sync-infra.pre-launcher.sh
  install -m 700 /opt/infra/state/sync-launcher.new /opt/infra/bin/sync-infra.sh.new
  mv -fT /opt/infra/bin/sync-infra.sh.new /opt/infra/bin/sync-infra.sh
  rm -f /opt/infra/state/sync-launcher.new
'
sudo systemctl start infra-sync.service
sudo systemctl status infra-sync.service --no-pager
sudo cat /opt/infra/state/sync-status
sudo cat /opt/infra/state/last-sync-commit
sudo systemctl start infra-sync.timer
sudo systemctl list-timers infra-sync.timer
```

Check installed registry, public CLI commands, backup logs and container health after the first run. If migration fails before worker installation, restore the old executable with `sudo install -m 700 /opt/infra/state/sync-infra.pre-launcher.sh /opt/infra/bin/sync-infra.sh`. A launcher rollback does not restore files changed by a worker. If `sync-status` says `recovery-required`, preserve `/opt/infra/state/sync-transaction`, inspect the installed files and restore from its `old` copies before retrying. Do not change credentials, cron or Dockhand during migration.
