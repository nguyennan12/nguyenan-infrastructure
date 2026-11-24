# Nguyen An Infrastructure

Personal self-hosted infrastructure for multiple backend projects, running on an Azure Ubuntu VPS with Docker Compose. PostgreSQL, Redis and MinIO provide shared data services with separate project credentials. Traefik provides TLS ingress; Restic and Rclone provide encrypted off-site backups to Google Drive.

## Services

| Service | Application endpoint | Administration |
|---|---|---|
| PostgreSQL 17 + PgBouncer | `postgres.static4j.app:6433` (TLS) | pgAdmin via `127.0.0.1:15432` |
| Redis 8 | `redis.static4j.app:6380` (TLS) | RedisInsight via `127.0.0.1:16379` |
| MinIO | `https://minio.static4j.app` | `http://127.0.0.1:9001` |
| Dockhand | Private | `http://127.0.0.1:13000` |
| Cockpit | Private | `https://127.0.0.1:9090` |
| Traefik | TCP 80/443/6380/6433 | `http://127.0.0.1:8080/dashboard/` |

Administration endpoints require SSH local forwarding (or local access). Application ports require appropriate Azure NSG rules. Use project-specific credentials, not administrator accounts.

## Repository layout

```text
.github/workflows/infrastructure-ci.yml
configs/
  pgbouncer/setup-auth.sql
  traefik/dynamic/tls.yml
  systemd/infra-sync.service
  systemd/infra-sync.timer
scripts/
  bootstrap.sh, setup-*.sh
  backup-*.sh, maintenance.sh
  restore-*.sh
  create-project.sh, add-service.sh, remove-service.sh
  delete-project.sh, list-projects.sh, sync-infra.sh
  lib/common.sh, postgres.sh, redis.sh, minio.sh
stacks/{gateway,database,cache,storage}.yml
docs/
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

## Backup

Daily at 02:00 Asia/Ho_Chi_Minh; maintenance on Sunday at 05:00. Retention: 7 daily, 4 weekly, 3 monthly snapshots per backup group. Google Drive repository: `rclone:gdrive-backup:static4j-backup-v2`. Backup and file restoration have been tested; full service recovery on a separate host remains to be tested. Scheduled execution must be verified from logs.

## Secrets

Never commit live `.env` files, OAuth tokens, Redis ACL hashes, PgBouncer userlists, SQL dumps, TLS private keys or Restic passwords. Use a password manager and restricted local files. Keep recovery credentials outside the VPS.

## Quick start (existing VPS)

```bash
sudo /opt/infra/scripts/create-project.sh myapp --all
sudo /opt/infra/scripts/list-projects.sh
sudo /opt/infra/scripts/add-service.sh myapp --redis
sudo /opt/infra/backup/backup-all.sh
```

The add command is illustrative; it skips a service already present. See the project guide for selective provisioning, connection settings and destructive operations. Do not run bootstrap on the existing VPS.

## GitOps

Push changes to `main`. CI validates Compose and Bash, runs secret scanning, then promotes successful main pushes to `production`. Dockhand tracks production for stack deployments; a separate systemd timer tracks production for installed scripts. Both poll at approximately five-minute intervals. Revert a specific bad commit on main rather than force-pushing production. See [Deployment](docs/DEPLOYMENT.md).

## Status — 2026-11-24

- Six running containers; PostgreSQL/Redis/MinIO project isolation exercised in test projects, with manual VitaFlix resources outside V2 management.
- GitOps label deployment and revert observed on Redis; MinIO fix commit preserved.
- Modular create/add/remove exercised. A failed MinIO deletion was repaired and completed manually; automatic end-to-end deletion after the fix was intentionally not retested.
- Restic integrity check and restoration of files from four backup groups succeeded. Full independent-host recovery and recovery time remain unverified.
- Duplicate daily cron entry was observed; removal and absence of other schedules should be verified. No external application deployment is required or claimed.
- Suggested first release: `v1.0.0-rc.1`; final release subject to recovery and deletion validation. Legacy migration intentionally omitted.

Documentation reflects the observed setup and prior runbook, not a fresh audit of every source file or live configuration.
