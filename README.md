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
configs/
  pgbouncer/setup-auth.sql
  traefik/dynamic/tls.yml
scripts/
  backup-all.sh
  backup-infra.sh
  backup-minio.sh
  backup-postgres.sh
  backup-redis.sh
  maintenance.sh
stacks/
  gateway.yml
  database.yml
  cache.yml
  storage.yml
docs/
.env.example
.gitignore
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

## Status

Initial infrastructure and backup setup completed. Security hardening, external application integration and full disaster recovery testing remain validation tasks. Git-based deployment is a future option; existing stacks are managed through Dockhand.
