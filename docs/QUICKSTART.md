# Quick Start

[README](../README.md) · [Configuration](CONFIGURATION.md) · [Deployment details](DEPLOYMENT.md)

This is an installation outline for a **clean Ubuntu 24.04 VPS**, not a command sequence to rerun on an existing host. Root access, DNS control, outbound access to package repositories and a trusted clone are required. The installer installs Docker/Compose, Git, jq, Restic and Rclone, configures the `proxy` network, and creates 2 GiB swap when none exists. Check available disk and memory for your workload; a 1 GiB host has been observed in production but is not a capacity guarantee.

1. Configure DNS for `postgres.example.com`, `redis.example.com` and `minio.example.com` to the new VPS. Allow the intended client ports through your cloud firewall. Keep administrative ports private.
2. Clone your trusted fork or copy of this repository to `/opt/infra/repository` using credentials appropriate to its visibility. For example, replace the URL below with your reviewed repository URL. Do not commit environment files or deploy keys.

   ```bash
   sudo apt-get update
   sudo apt-get install -y git
   sudo install -d -m 755 /opt/infra
   sudo git clone https://github.com/your-org/your-repo.git /opt/infra/repository
   cd /opt/infra/repository
   ```

   The host needs Git for this step. Bootstrap installs `jq`; after installation, `bash scripts/validation/validate-registry.sh` validates the clone's metadata.
3. Preview the interactive installer with `sudo bash scripts/bootstrap.sh --plan`. It asks for installation type, domain, Standalone/GitOps mode, Cockpit, optional backup and confirmation; the plan does not change the host.
4. On a **new** host, run `sudo bash scripts/bootstrap.sh`. Use a real domain; `example.com` is accepted only after an extra testing confirmation. Existing `infrastructure.env`, `deployment.env` and secret files are preserved or rejected on mismatch rather than silently replaced.
5. For Standalone, bootstrap initializes stack secrets and runs `deploy.sh`. Check with `sudo /opt/infra/scripts/deploy.sh --check`, `sudo /opt/infra/scripts/list-services.sh` and `docker ps --format '{{.Names}} {{.Status}}'`. For GitOps, bootstrap installs Dockhand and the sync timer; manually register the four stack files in Dockhand using their exact project names and environment values. [GitOps guide](GITOPS.md).
6. Configure [backup](BACKUP-RESTORE.md) and [monitoring](MONITORING.md) only if required. Store Restic recovery credentials off-host. Monitoring needs an existing protected Discord webhook before its timer can be enabled.

Fresh installation and complete service recovery have **not** been verified end to end on an independent host. Review [disaster recovery](DISASTER-RECOVERY.md) before relying on the platform for irreplaceable data. Never run both Standalone and Dockhand against the same Compose stacks.
