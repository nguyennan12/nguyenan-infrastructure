# Nguyen An Infrastructure

Reusable self-hosted infrastructure for multiple backend projects on Ubuntu 24.04 with Docker Compose. PostgreSQL, Redis and MinIO provide shared data services with separate project credentials. Traefik provides TLS ingress; Restic and Rclone provide encrypted off-site backups to Google Drive.

New installations can use either **Standalone** deployment through Docker Compose CLI or **GitOps** deployment through Dockhand. Both modes use the same stack definitions, provisioning modules, backup scripts and restore scripts. The existing production GitOps installation remains compatible and does not need `deployment.env`, portable secret files, bootstrap reruns or ownership migration.

## Services

| Service | Application endpoint | Administration |
|---|---|---|
| PostgreSQL 17 + PgBouncer | `postgres.${INFRA_DOMAIN}:6433` (TLS) | pgAdmin via `127.0.0.1:15432` |
| Redis 8 | `redis.${INFRA_DOMAIN}:6380` (TLS) | RedisInsight via `127.0.0.1:16379` |
| MinIO | `https://minio.${INFRA_DOMAIN}` | `http://127.0.0.1:9001` |
| Dockhand | Private | `http://127.0.0.1:13000` |
| Cockpit | Private | `https://127.0.0.1:9090` |
| Traefik | TCP 80/443/6380/6433 | `http://127.0.0.1:8080/dashboard/` |

Administration endpoints require SSH local forwarding (or local access). Application ports require appropriate Azure NSG rules. Use project-specific credentials, not administrator accounts. Default examples in documentation use `example.com` (e.g., `postgres.example.com:6433`).

## Infrastructure domain configuration

The infrastructure uses a single base domain configuration:

- **VPS Runtime**: `/opt/infra/infrastructure.env` contains `INFRA_DOMAIN=example.com` (mode 600, root:root).
- **Dockhand Stacks**: Environment variable `INFRA_DOMAIN=example.com` configured for `infra-database`, `infra-cache`, and `infra-storage`.
- **Derived Endpoints**:
  - PostgreSQL: `postgres.${INFRA_DOMAIN}:6433`
  - Redis: `redis.${INFRA_DOMAIN}:6380`
  - MinIO: `https://minio.${INFRA_DOMAIN}`

This decoupling allows deploying the infrastructure on any VPS or new domain without modifying source code.

## Repository layout

```text
.github/workflows/infrastructure-ci.yml
configs/
  pgbouncer/setup-auth.sql
  traefik/dynamic/tls.yml
  systemd/infra-sync.service
  systemd/infra-sync.timer
  systemd/infra-monitor.service
  systemd/infra-monitor.timer
scripts/
  bootstrap.sh
  core/{common,registry}.sh
  setup/setup-*.sh
  deployment/{deploy,update,sync-launcher,sync-infra}.sh
  monitoring/{monitor,checks,notify,setup-monitoring}.sh
  projects/{orchestrator,create-project,add-service,remove-service,delete-project,list-projects,list-services}.sh
  backup/{backup-all,backup-infra,maintenance}.sh
  restore/{restore-all,restore-infra}.sh
  services/{postgres,redis,minio}/{adapter,provision,backup,restore}.sh
  validation/validate-registry.sh
registry/{stacks,services}.json
stacks/{gateway,database,cache,storage}.yml
docs/
infrastructure.env.example
deployment.env.example
.env.example
.gitignore
.gitattributes
README.md
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md): services, networking and isolation.
- [Deployment](docs/DEPLOYMENT.md): bootstrap and deployment order.
- [Disaster recovery](docs/DISASTER-RECOVERY.md): backup and recovery procedure.
- [Security](docs/SECURITY.md): firewall, access and hardening.
- [Create a project](docs/CREATE-PROJECT.md): provision application credentials and storage.
- [Add a service](docs/ADD-SERVICE.md): extend stacks, project hooks, backup and restore safely.
- [Monitoring](docs/MONITORING.md): optional host, service, backup and GitOps alerts.

## Backup

The example schedule is daily at 02:00 Asia/Ho_Chi_Minh and maintenance on Sunday at 05:00. Retention is 7 daily, 4 weekly and 3 monthly snapshots per backup group. Configure your own Restic URL, such as `rclone:<remote>:<repository-folder>`. Full service recovery on a separate host has not been verified.

For a new host, bootstrap can open Rclone's interactive Google Drive configuration, import an existing `rclone.conf`, or skip backup setup. Rclone handles optional custom OAuth client credentials and browser/headless authorization. Fresh setup can accept or securely generate a Restic password and initializes a repository only after explicit `INITIALIZE` confirmation. Restore preparation accepts existing credentials only, verifies access, lists snapshots and never enables cron.

Existing backup files are preserved. `setup-cron.sh` refuses to create a schedule when matching root crontab or other `/etc/cron.d` entries already exist.

To configure a deferred fresh backup later:

```bash
sudo /opt/infra/scripts/setup-backup.sh --fresh
sudo /opt/infra/scripts/setup-cron.sh
```

Run the cron command only after repository verification succeeds. On a recovery host use `setup-backup.sh --restore`; do not run `setup-cron.sh` until service recovery has been validated.

## Secrets

Never commit live `.env` files, OAuth tokens, Redis ACL hashes, PgBouncer userlists, SQL dumps, TLS private keys or Restic passwords. Use a password manager and restricted local files. Keep recovery credentials outside the VPS.

## Quick start (existing VPS)

```bash
sudo /opt/infra/scripts/create-project.sh myapp --all
sudo /opt/infra/scripts/list-projects.sh
sudo /opt/infra/scripts/list-services.sh
sudo /opt/infra/scripts/add-service.sh myapp --redis
sudo /opt/infra/backup/backup-all.sh
```

The add command is illustrative; it skips a service already present. See the project guide for selective provisioning, connection settings and destructive operations. Do not run bootstrap on the existing VPS.

## Fresh VPS installation

Clone the trusted repository on a fresh Ubuntu 24.04 VPS, preferably at `/opt/infra/repository`, and run:

```bash
sudo bash ./scripts/bootstrap.sh
```

The installer displays a plan before changing the host. It asks for fresh installation or restore preparation, domain, Standalone or GitOps ownership, optional Cockpit and optional backup configuration. `example.com` requires a separate testing confirmation. DNS, firewall rules and Google Drive OAuth remain manual steps.

### Standalone

The installer records the absolute trusted clone path in `/opt/infra/deployment.env`, creates separate mode-600 stack files under `/opt/infra/secrets`, and deploys with the existing project names. Later validation, deployment and opt-in updates use:

```bash
sudo /opt/infra/scripts/deploy.sh --check
sudo /opt/infra/scripts/deploy.sh
sudo /opt/infra/scripts/update.sh
```

`update.sh` is never scheduled automatically. It refuses a dirty repository, validates the fetched target in a temporary Git worktree and records the deployed revision. It does not pull images blindly or delete volumes.

### GitOps

GitOps continues to use Dockhand and the `production` branch. For a new GitOps host, register the existing four stack files with project names `infra-gateway`, `infra-database`, `infra-cache` and `infra-storage`. Supply each stack's variables explicitly in Dockhand; Dockhand does not automatically consume `/opt/infra/secrets/*.env`. Do not move current production credentials out of Dockhand merely to adopt this installer.

Standalone and Dockhand must never control the same stacks. Automatic ownership migration is intentionally absent.

## GitOps

Push changes to `main`. CI validates Compose and Bash, runs secret scanning, then promotes successful main pushes to `production`. Dockhand tracks production for stack deployments; a separate systemd timer tracks production for installed scripts. Both poll at approximately five-minute intervals. Revert a specific bad commit on main rather than force-pushing production. See [Deployment](docs/DEPLOYMENT.md).

The stable launcher at `/opt/infra/bin/sync-infra.sh` fetches the validated production revision and executes its versioned worker. The launcher itself and systemd units require an explicit installation or update; see [the migration guide](docs/SYNC-LAUNCHER-MIGRATION.md). This does not activate Standalone deployment.

The repository uses domain-based source directories, while installed public commands remain at their established paths such as `/opt/infra/scripts/create-project.sh`, `/opt/infra/scripts/deploy.sh` and `/opt/infra/backup/backup-all.sh`. Registry mappings install internal service files below `/opt/infra/scripts/services/` without changing cron or systemd command paths.

Stack and project-service discovery is driven by the validated JSON registries in `registry/`. Metadata selects only allowlisted handlers and adapter hooks; it is never evaluated as shell code. Existing PostgreSQL, Redis and MinIO modules remain the implementation behind the standardized adapters. An existing host without an installed registry keeps the legacy wrappers and backup/restore order, so this change does not force a production migration.

Operational observations from a particular host are not portable guarantees. Verify deployment, backup schedules, monitoring and recovery in each environment; full independent-host disaster recovery remains unverified.
