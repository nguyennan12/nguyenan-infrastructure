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

## Hardening and monitoring

Check Ubuntu security updates, Docker log rotation, resource pressure, open sockets and Azure NSG. Use `sudo ss -lntup`, `sudo docker ps`, `sudo sshd -T`, `sudo docker info` and inspect log configuration. Apply configuration changes deliberately; Docker daemon changes may require restart and recreated containers. Verify updates and access after changes. Security hardening is a checklist to complete, not a claim that this host is fully hardened.
