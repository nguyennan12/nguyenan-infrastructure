# Proposed v1.0.0 release notes

**Draft only. No release or tag has been published.**

## Included

- Infrastructure foundation: Ubuntu host setup, four Docker Compose stacks, protected configuration, resource limits, health checks, and log rotation.
- PostgreSQL 17 with PgBouncer; project-specific databases and roles.
- Redis 8 with persistent ACL users and project key prefixes.
- MinIO object storage with project buckets, IAM users, and policies.
- Traefik gateway for HTTPS, Redis TLS, and PostgreSQL STARTTLS ingress.
- Validated stack/service registries and Bash service adapters.
- Project create, list, add/remove service, and delete commands with shared locking and backup-before-remove/delete behavior.
- Standalone Compose ownership and updates, plus Dockhand GitOps deployment and a stable launcher for runtime script synchronization.
- Interactive Restic/Rclone setup, scheduled backups, retention, restore preparation, and snapshot listing.
- Optional host/service checks with Discord warning and recovery notifications.
- Security and reliability improvements: credential preservation, restricted secrets, CI secret scanning, bounded Docker logs, and MinIO `unless-stopped` restart policy.

## Known limitations

- Complete disaster recovery on an independent host has **not** been verified.
- Fresh installation has **not** been fully verified end to end.
- Resource requirements depend on workload; the observed small VPS is not a sizing guarantee.
- On-host monitoring cannot detect a complete host or network outage from outside.
- Dockhand stack deployment and runtime script synchronization are independently managed and may temporarily run different revisions.
- The platform does not provide high availability, atomic cross-service backups, guaranteed recovery objectives, or a production readiness guarantee.
- Dockhand has separate upstream license terms; review them before commercial production use. See [external software licenses](../THIRD-PARTY-LICENSES.md).

Read the [Quick Start](QUICKSTART.md), [deployment guide](DEPLOYMENT.md), [backup and restore guide](BACKUP-RESTORE.md), and [disaster recovery guide](DISASTER-RECOVERY.md) before operating a host.
