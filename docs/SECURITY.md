# Security

## Network policy

| TCP port | Purpose | Target policy |
|---|---|---|
| 22 | SSH | Administrator IP allowlist |
| 80 | ACME HTTP challenge | Public |
| 443 | MinIO HTTPS | Public if needed |
| 6433 | PostgreSQL TLS | Backend egress IP allowlist |
| 6380 | Redis TLS | Backend egress IP allowlist |
| 3000, 9090, 8080, 9000, 9001, 5432, 6432, 6379 | Internal/management | Not public |

The database and Redis TLS ports were opened for connectivity testing. Restrict them to known backend outbound IPs before production use. TLS protects traffic but does not prevent brute-force attempts or resource exhaustion. Azure default VNet rules may permit internal VNet access; use loopback bindings and evaluate lateral access separately.

## Authentication

- SSH: verify key-based login in a second session before disabling password and root login. Keep TCP forwarding enabled for management tunnels. Validate with `sshd -t` before reload.
- PostgreSQL: SCRAM-SHA-256, distinct project login roles, no superuser privileges in backend, restrict CONNECT on project databases. Keep admin and PgBouncer auth roles separate.
- Redis: persistent ACL file, distinct strong passwords, explicit key patterns and command allowlists. No admin commands for application roles. Save ACL and verify after restart.
- MinIO: private buckets and least-privilege IAM policies. Do not use root credentials in backend. Review maintenance/security status of the pinned legacy MinIO image before production.
- Dockhand: enable authentication; restrict access via SSH tunnel; Docker socket access is effectively root-level.

## Secrets and backup

Never commit live environment values, SQL dumps, Redis ACLs, PgBouncer userlist, ACME private keys, OAuth tokens or backup passwords. Inspect Compose command arguments as well as environment values. Rotate exposed credentials and update dependent services and backup scripts. Use separate project credentials. Protect restored backup files; Restic encryption does not protect plaintext staging files. Store Restic password separately from the VPS.

The runtime domain configuration file `/opt/infra/infrastructure.env` is restricted to permissions `600` (root:root) and excluded from Git. It stores only the base domain (`INFRA_DOMAIN`) and no secrets. Common loader functions parse it with strict regular expression validation to prevent shell injection or execution of arbitrary code.

New installations store deployment ownership in `/opt/infra/deployment.env` and portable credentials in stack-specific files below `/opt/infra/secrets`. Configuration readers parse allowed keys without evaluating file contents. Secret setup preserves existing values and fails on Redis credential disagreement. Keep shell tracing disabled around all privileged installation and deployment commands.

The backup wrapper never logs entered OAuth or Restic secrets; OAuth prompts and browser authorization are handled directly by Rclone. Generated Restic passwords remain in the protected mode-600 password file and must be copied manually from a private terminal to an off-host password manager. Restore mode never generates credentials or initializes a repository.

The Standalone owner marker prevents an unowned existing container set from being adopted silently. Detection is a safety boundary, not a substitute for access control: only root should modify `/opt/infra`, the repository checkout or systemd units.

Registry files are untrusted input until validation succeeds. Validation confines referenced files to the trusted repository or installed infrastructure root, rejects traversal and duplicate destinations, verifies dependency graphs and accepts only fixed deployment handlers, readiness types, secret generators and service hook names. No registry field is executed with `eval`. Root synchronization installs only declared files into restricted script, backup, restore and stack destinations, then publishes the registry last.

## Hardening and monitoring

Check Ubuntu security updates, Docker log rotation, resource pressure, open sockets and Azure NSG. Use `sudo ss -lntup`, `sudo docker ps`, `sudo sshd -T`, `sudo docker info` and inspect log configuration. Apply configuration changes deliberately; Docker daemon changes may require restart and recreated containers. Verify updates and access after changes. Security hardening is a checklist to complete, not a claim that this host is fully hardened.

## GitOps and root execution trust

The GitHub repository is private; a read-only deploy key is used by the VPS checkout. CI promotes main to production with write permission only for the promotion job. Restrict repository collaborators, secure GitHub accounts with MFA, review changes to shell scripts/workflows, and protect branches when feasible. Branch protection is not currently enabled. Any malicious approved script update can execute with root privileges through scheduled tasks. Gitleaks is helpful but does not prove that no secrets exist.

## Current gaps and decisions

Public TLS database/cache ports were intentionally left open to Any in NSG for now; allowlisting is recommended before exposing real workloads. No password rotation is claimed. Verify management sockets, TLS certificate validation and permissions after updates. Never expose the Docker socket or administrative consoles publicly. MinIO image maintenance and mutable tags (`latest`, major-only tags) need review; pin tested versions or digests before relying on reproducible recovery. There is no demonstrated HA, tenant resource quota or full independent-host restore. Do not publish live `.env`, backup configuration or restored files. Keep an offline copy of the Restic password and original OAuth app details.
