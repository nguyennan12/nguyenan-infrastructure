# Project Management

[Quick Start](QUICKSTART.md) · [Architecture](ARCHITECTURE.md) · [Detailed isolation notes](CREATE-PROJECT.md)

Commands below refer to installed runtime paths. Run them as root on the host. Project names must start with a lowercase letter, contain only lowercase letters/digits and be 3–30 characters long. `--help` and `-h` print usage before project-name validation.

| Task | Command |
|---|---|
| List managed and legacy projects | `sudo /opt/infra/scripts/list-projects.sh` |
| List registered, enabled, available, deployed and healthy services | `sudo /opt/infra/scripts/list-services.sh` |
| Create with selected services | `sudo /opt/infra/scripts/create-project.sh demoapp --services postgres,redis` |
| Add one service | `sudo /opt/infra/scripts/add-service.sh demoapp --minio` |
| Remove one service | `sudo /opt/infra/scripts/remove-service.sh demoapp --redis` |
| Delete project | `sudo /opt/infra/scripts/delete-project.sh demoapp` |

Create/add accept `--services postgres,redis` or `--services=postgres,redis`, legacy flags `--postgres`, `--redis`, `--minio`, and `--all`. Create without flags offers interactive selection. Remove accepts `--services` or the legacy individual flags; it has no `--all`. Add/remove require a service argument. An already provisioned service is skipped. Dependencies are validated against the registry.

There is no separate `show-project` CLI. `list-projects.sh` displays status and services; to inspect a single manifest, run `sudo jq '{name,status,services}' /opt/infra/projects/demoapp/project.json`. Credentials are in `/opt/infra/projects/demoapp/.env` (mode 600). Open that file only in a private root session; never paste it into logs, issues or frontend configuration.

Provisioning creates a PostgreSQL database/role, a Redis ACL user and key prefix, and a MinIO bucket/user/policy when those services are selected. These are logical access boundaries, not separate resource quotas. The manifest records provisioned service flags. Legacy projects can be listed but require reviewed migration before registry-based lifecycle operations.

The CLI asks for the exact phrases `CREATE demoapp`, `ADD demoapp`, `REMOVE demoapp` and `DELETE demoapp`. **Remove and delete are destructive**: they acquire backup and provisioning locks, run a complete backup first, then remove the selected resources. If backup fails, removal does not start. A failure during provisioning or deletion can leave `incomplete` metadata and partial resources; inspect the actual resources and backup before retrying. No automatic project-operation rollback exists. See [failure handling](CREATE-PROJECT.md) and [backup and restore](BACKUP-RESTORE.md).
