# Deployment

For Phase 3.1 GitOps synchronization and the one-time launcher transition, use [SYNC-LAUNCHER-MIGRATION.md](SYNC-LAUNCHER-MIGRATION.md). Earlier manual worker installation instructions below describe the pre-3.1 layout and must not be used for a 3.1 migration.

The interactive bootstrap supports fresh Standalone or GitOps installation and isolated restore preparation. Review the actual Compose files and image versions before execution. For recovery of an existing installation, read DISASTER-RECOVERY.md first.

## Deployment modes

New hosts require `/opt/infra/deployment.env` with exactly `DEPLOYMENT_MODE=standalone` or `DEPLOYMENT_MODE=gitops`, plus the absolute trusted `REPOSITORY_DIR`. The file lives outside Git and is never overwritten automatically. Existing production without this file remains a valid GitOps installation; do not create the file unless deliberately adopting the new tooling.

Standalone uses `deploy.sh` with explicit Compose project names. GitOps uses Dockhand. Running both controllers against the same stacks is prohibited, and this repository does not automate ownership migration.

## Prerequisites

- Ubuntu 24.04 VPS, SSH key access, Docker Engine and Compose plugin.
- DNS control for your base domain (e.g., `example.com`), Azure NSG access, private Git repository access.
- A password manager, Google Drive account and dedicated Google OAuth desktop client for backup.

## Interactive bootstrap

Run from a trusted clone on a fresh Ubuntu 24.04 host. `/opt/infra/repository` is the recommended clone location:

```bash
sudo bash ./scripts/bootstrap.sh
```

Use `./scripts/bootstrap.sh --plan` to exercise the prompts and print the plan without changing the machine. Restore preparation installs only base prerequisites and configuration; it does not generate service credentials, create stateful volumes, install/start Dockhand or deploy services.

For a fresh Standalone installation the installer runs the existing setup modules, creates explicit deployment configuration, initializes portable secrets, and calls `deploy.sh`. For a new GitOps installation it installs Dockhand and prints the remaining registration steps. Cockpit is optional in both cases.

When backup is selected, the installer offers interactive Google Drive setup through Rclone, import of an existing `rclone.conf`, or deferral. Rclone presents optional custom OAuth Client ID/Secret fields and browser/headless authorization. Fresh setup asks for the remote, repository folder or full Restic URL, source host and Restic password. A generated password is never printed automatically; copy it from a private terminal into an off-host password manager before relying on the backup.

Restic repository initialization requires the exact confirmation `INITIALIZE` and is offered only in fresh mode after access verification fails. Restore preparation requires existing credentials, verifies the repository, lists snapshots and never initializes a repository or enables cron.

Scheduling remains 02:00 daily and 05:00 Sunday. Before writing `/etc/cron.d/infra-backup`, setup checks root crontab and other cron files for duplicate backup commands.

For deferred fresh setup, run `setup-backup.sh --fresh`, verify the reported snapshots/repository, store the recovery password off-host, and only then run `setup-cron.sh`. `setup-backup.sh --restore` intentionally has no scheduling side effect.

## Manual bootstrap reference

1. Install Docker using the official Ubuntu instructions and install `restic`, `rclone`, `cron` via apt. Configure swap if necessary, and verify available RAM/disk.
2. Clone the private repository using authorized credentials. Create a local `.env` from `.env.example`, restrict permissions and populate real secrets outside Git.
   Create and configure the infrastructure domain file:
   ```bash
   sudo cp infrastructure.env.example /opt/infra/infrastructure.env
   sudo chmod 600 /opt/infra/infrastructure.env
   # Set INFRA_DOMAIN=example.com in /opt/infra/infrastructure.env
   ```
   In Dockhand, set the equivalent variables separately for each stack, including `INFRA_DOMAIN=example.com` for `infra-database`, `infra-cache`, and `infra-storage`.
3. Create the shared network if absent:

   ```bash
   docker network inspect proxy >/dev/null 2>&1 || docker network create proxy
   sudo install -d /opt/infra/traefik/dynamic
   sudo install -m 644 configs/traefik/dynamic/tls.yml /opt/infra/traefik/dynamic/tls.yml
   ```
4. Point DNS A records for subdomains to the new VPS IP:
   - `postgres.<INFRA_DOMAIN>` -> VPS IP
   - `redis.<INFRA_DOMAIN>` -> VPS IP
   - `minio.<INFRA_DOMAIN>` -> VPS IP
   Configure NSG as in SECURITY.md. For migration, defer production DNS cutover until validation; ACME HTTP challenge requires reachable port 80 and matching DNS.
5. Deploy gateway, then database, cache and storage. Keep Compose project names `infra-gateway`, `infra-database`, `infra-cache`, `infra-storage` unchanged to preserve named-volume mapping. Inspect `docker compose config` locally (it can reveal secrets; do not share output). In Standalone mode, `deploy.sh` performs this ordering and fresh authentication initialization.

## Portable secrets

`setup-secrets.sh` discovers variables referenced by the Compose files and refuses to proceed if the expected contract changes without review. It creates:

```text
/opt/infra/secrets/gateway.env
/opt/infra/secrets/database.env
/opt/infra/secrets/cache.env
/opt/infra/secrets/storage.env
```

The directory is mode 700 and files are mode 600, root-owned. Existing values are preserved. The script never prints credentials or rotates them. Explicit values may be supplied as environment variables for controlled automation; otherwise strong passwords are generated. The Redis administrator value is mirrored to the existing protected backup password file. A mismatch causes failure instead of rotation.

For GitOps, enter the corresponding values in each Dockhand stack. `infra-gateway` needs `ACME_EMAIL`; `infra-database` needs `INFRA_DOMAIN`, `POSTGRES_PASSWORD` and `PGBOUNCER_AUTH_PASSWORD`; `infra-cache` needs `INFRA_DOMAIN` and `REDIS_PASSWORD`; `infra-storage` needs `INFRA_DOMAIN`, `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`. Host secret files are not automatically imported by Dockhand.

## Standalone deploy and update

```bash
sudo /opt/infra/scripts/deploy.sh --check
sudo /opt/infra/scripts/deploy.sh
sudo /opt/infra/scripts/update.sh
```

Deployment validates every stack before container changes, preserves names and volumes, initializes PgBouncer authentication and Redis ACL only when absent, and checks PostgreSQL, PgBouncer, Redis and MinIO readiness. It never uses destructive volume operations.

Standalone stack discovery now comes from the validated registry. Dependencies determine deployment order, while explicit Compose project names preserve existing container, network and volume ownership. A registered stack is not deployed until it is enabled. Generic future stacks receive Compose validation and declared container readiness; the existing gateway/database/cache/storage handlers retain their current initialization behavior.

Updates are manual. `STANDALONE_BRANCH` in `deployment.env` identifies the trusted remote branch. The updater refuses local modifications, validates the fetched commit in a temporary worktree, coordinates with deployment/backup/provisioning/restore locks, deploys without deleting data and records current and previous revisions.

Rollback of infrastructure code is manual: inspect `/opt/infra/state/previous-deployed-commit`, check out that trusted revision in a clean repository, run `deploy.sh --check`, then `deploy.sh`. A code rollback cannot restore database schemas, service data, deleted objects or previous secret values.

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

## Bootstrap scripts and installation paths

The repository includes `bootstrap.sh`, `setup-*.sh`, and `restore-*.sh`. Bootstrap expects root, Ubuntu 24.04 and no existing containers. Run from the checked-out repository so relative config paths resolve. For recovery, restore optional Dockhand data before starting it. Do not run setup-cron on an existing host without reconciling its root crontab.

## GitOps workflow

The repository uses `main` for changes and `production` for deployments. `.github/workflows/infrastructure-ci.yml` checks Compose with non-live environment values, recursively validates Bash syntax and ShellCheck errors, scans secrets with Gitleaks, and promotes successful main pushes. Pull requests validate without promoting. This is not a runtime integration test; configure branch protection to suit your repository.

Dockhand uses branch `production`, the four stack files and scheduled sync every five minutes. Keep existing stack names and secrets. A separate root systemd service/timer runs the stable launcher at `/opt/infra/bin/sync-infra.sh`; it pins the production commit and executes the versioned worker from that commit. The worker installs allowlisted runtime files and advances `/opt/infra/state/last-sync-commit` after verification. The launcher and systemd units require explicit updates.

The worker validates metadata and source files before installation, stages rollback copies and installs registry metadata last. A failed or interrupted installation may require recovery; inspect `sync-status` and the migration guide. This does not change Dockhand ownership. Any new enabled Compose stack must also be registered manually in Dockhand with the exact registry project name and environment.

### Existing-host launcher transition

Install the stable launcher once using the reviewed procedure in [SYNC-LAUNCHER-MIGRATION.md](SYNC-LAUNCHER-MIGRATION.md). Preserve the existing revision marker and verify one monitored synchronization before relying on the timer.

Do not enable or schedule the Standalone `update.sh` on a GitOps host.

```bash
sudo systemctl list-timers infra-sync.timer
sudo systemctl start infra-sync.service
sudo journalctl -u infra-sync.service -n 30 --no-pager
```

## Rollback

Inspect the offending commit; revert that commit on main, not the whole production branch. Resolve conflicts and review the resulting diff before push. For the completed Redis label test the revert was `a525e87`, preserving MinIO fix `3447851`.

```bash
git log -5 --oneline
git fetch origin
git log -3 --oneline origin/production
```

After a new revert is promoted, check Dockhand sync and container health; separately check installed script sync if affected. Redis test label `infra.rollback-test` appeared and later disappeared after revert. Git rollback does not restore deleted data, previous secret values or incompatible on-disk schemas.

## Domain change procedure

To migrate infrastructure to a new domain or rename `INFRA_DOMAIN`:

1. **DNS configuration**:
   Add DNS A records on the new DNS provider pointing to the VPS public IP:
   - `postgres.<NEW_DOMAIN>` -> `<VPS_IP>`
   - `redis.<NEW_DOMAIN>` -> `<VPS_IP>`
   - `minio.<NEW_DOMAIN>` -> `<VPS_IP>`
2. **Update VPS configuration**:
   Edit `/opt/infra/infrastructure.env`:
   ```dotenv
   INFRA_DOMAIN=newdomain.com
   ```
   Ensure permissions remain `600` (owned by `root:root`).
3. **Update Dockhand stack environments**:
   In Dockhand UI:
   - For `infra-database`: Update `INFRA_DOMAIN=newdomain.com` and redeploy stack.
   - For `infra-cache`: Update `INFRA_DOMAIN=newdomain.com` and redeploy stack.
   - For `infra-storage`: Update `INFRA_DOMAIN=newdomain.com` and redeploy stack.
   Traefik detects the updated router rules and issues new Let's Encrypt certificates via ACME HTTP challenge.
4. **Update existing projects**:
   Update connection strings in existing project `.env` files (`/opt/infra/projects/<name>/.env`) and dependent applications as described in `CREATE-PROJECT.md`.

## Routine operations

```bash
free -h
df -h /
vmstat 1 5
sudo docker ps
sudo docker stats --no-stream
sudo docker system df
sudo crontab -l
sudo grep -R -n 'backup-all.sh\|maintenance.sh' /etc/cron.d /etc/crontab
```

The 24 November resource review found a duplicate 02:00 backup line. Keep exactly one daily and one weekly schedule across root crontab and `/etc/cron.d`; verify the correction. Do not prune unused volumes indiscriminately. Review service logs, OOM events and swap-in/out under load.
