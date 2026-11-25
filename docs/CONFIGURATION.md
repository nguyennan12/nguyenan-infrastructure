# Configuration Reference

[Quick Start](QUICKSTART.md) · [Deployment](DEPLOYMENT.md) · [Security](SECURITY.md)

The bootstrap writes `/opt/infra/infrastructure.env` and `/opt/infra/deployment.env` for new installations. Standalone stack secrets live in `/opt/infra/secrets/*.env` (directory mode 700, files mode 600); GitOps stack values must be entered in Dockhand. Do not commit real values. Existing configuration and credentials are preserved; mismatched deployment ownership or domain causes setup to stop.

| Name | Purpose | Required / default | Example | Secret? |
|---|---|---|---|---|
| `INFRA_DOMAIN` | Base DNS domain; derives `postgres`, `redis`, `minio` hosts | Required; no production default | `example.com` | No |
| `DEPLOYMENT_MODE` | Compose owner | Required for new deployment commands; `standalone` or `gitops` | `standalone` | No |
| `REPOSITORY_DIR` | Trusted checkout used by Standalone update | Written by bootstrap; recommended `/opt/infra/repository` | `/opt/infra/repository` | No |
| `STANDALONE_BRANCH` | Manual update source | Required by `update.sh`; bootstrap writes `main` | `main` | No |
| `ACME_EMAIL` | Certificate contact in gateway stack | Required by enabled gateway | `admin@example.com` | No |
| `POSTGRES_PASSWORD` | PostgreSQL administrator | Required by database stack; generated if absent | generated | Yes |
| `PGBOUNCER_AUTH_PASSWORD` | PgBouncer auth role | Required by database stack; generated if absent | generated | Yes |
| `REDIS_PASSWORD` | Redis administrator | Required by cache stack; generated if absent | generated | Yes |
| `MINIO_ROOT_USER` | MinIO root user | Required by storage stack; generator defaults to `infra_admin` | `infra_admin` | No |
| `MINIO_ROOT_PASSWORD` | MinIO root password | Required by storage stack; generated if absent | generated | Yes |

Backup is optional. Its protected `/opt/infra/backup/.env` has these required values when configured:

| Name | Purpose | Default / example | Secret? |
|---|---|---|---|
| `RESTIC_REPOSITORY` | Rclone-backed Restic URL | Fresh setup suggests `rclone:<remote>:infra-backup` | URL is not a password; protect repository details |
| `RCLONE_CONFIG` | Path to Rclone OAuth configuration | `/opt/infra/backup/rclone.conf` | Path: no; file contents: yes |
| `RESTIC_PASSWORD_FILE` | Path to Restic encryption password | `/opt/infra/backup/.restic-password` | Path: no; file contents: yes |
| `SOURCE_HOST` | Host recorded in snapshots; used to select restore snapshots | Fresh setup uses `hostname -s` | No |

`setup-backup.sh --fresh` creates or imports them interactively; `--restore` accepts only existing repository credentials. Fresh repository initialization requires the exact `INITIALIZE` confirmation. No Restic password is printed automatically. Store a separate recovery copy outside the VPS.

Optional monitoring settings are environment variables of `infra-monitor.service`: `CPU_LIMIT=90` (%), `RAM_MIN_MIB=100`, `SWAP_LIMIT=80` (%), `DISK_LIMIT=85` (%), `TLS_WARN_DAYS=14`, and `MONITOR_ROOT_TLS=1` only if the root domain serves HTTPS. Defaults apply when unset. The webhook is **not** an environment variable: place it in `/opt/infra/monitoring/.discord-webhook` with mode 600, root owned. See [monitoring](MONITORING.md).

The common library also accepts `INFRA_ROOT`, `INFRA_CONFIG_FILE`, `DEPLOYMENT_CONFIG_FILE` and, for deployment tools, an explicit `REPO_DIR`. Explicit `REPO_DIR` wins over the configured `REPOSITORY_DIR`; otherwise the deployment scripts read that file and fall back to their repository-location detection. These overrides are for controlled testing or nonstandard layouts, not a new configuration framework. The registry defaults to the repository's `registry/` in a clone and `/opt/infra/registry/` in installed runtime.

Runtime state is under `/opt/infra/state/`; project credentials and manifests are under `/opt/infra/projects/<project>/`. The public script entrypoints remain in `/opt/infra/scripts/`, backup commands in `/opt/infra/backup/`, and the GitOps launcher in `/opt/infra/bin/sync-infra.sh`. The revision marker is `state/last-sync-commit`, not necessarily the checkout's `HEAD`.
