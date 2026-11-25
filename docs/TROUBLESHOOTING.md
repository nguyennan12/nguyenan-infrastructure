# Troubleshooting

[Architecture](ARCHITECTURE.md) · [GitOps](GITOPS.md) · [Backup and Restore](BACKUP-RESTORE.md) · [Monitoring](MONITORING.md)

Start with read-only checks. Do not paste secret files, full environment output or Docker inspect JSON into issues. Operations that restart services, modify credentials, restore data or alter DNS require a separate reviewed plan.

| Symptom | Read-only diagnostics | What to verify |
|---|---|---|
| Container does not start | `docker ps -a --format '{{.Names}} {{.Status}}'`; `docker logs --tail 50 infra-postgres` (adjust container name) | Compose project name, required environment, memory/OOM and image availability; redact logs before sharing |
| DNS or TLS fails | `getent hosts minio.example.com`; `openssl s_client -connect minio.example.com:443 -servername minio.example.com </dev/null` | DNS, firewall, certificate expiry and SNI; root-domain HTTPS is not required by default |
| PostgreSQL/PgBouncer connection fails | `docker ps --filter name=infra-postgres --filter name=infra-pgbouncer`; `docker logs --tail 50 infra-pgbouncer` | PostgreSQL health before PgBouncer, TLS via public `:6433`, transaction pooling and role privileges |
| Redis authentication fails | `docker ps --filter name=infra-redis`; `docker logs --tail 50 infra-redis` | Correct project ACL user, password, key prefix and TLS endpoint `:6380`; avoid commands that echo passwords |
| MinIO unreachable | `docker ps --filter name=infra-minio`; `docker logs --tail 50 infra-minio` | Public `minio.<domain>:443`, local API `127.0.0.1:9000`, bucket/user/policy and DNS |
| Backup fails or is overdue | `sudo cat /opt/infra/state/backup-status`; `sudo tail -n 50 /opt/infra/backup/backup.log`; `sudo systemctl status cron --no-pager` | Aggregate exit status, each service group, repository access, quota and backup lock |
| GitOps sync fails | `sudo cat /opt/infra/state/sync-status`; `sudo journalctl -u infra-sync.service -n 50 --no-pager`; `sudo systemctl list-timers infra-sync.timer` | Fetch, pinned worker, registry validation, locks and recovery-required transaction; do not discard rollback files |
| Monitoring alert absent | `sudo systemctl status infra-monitor.timer infra-monitor.service --no-pager`; `sudo journalctl -u infra-monitor.service -n 50 --no-pager`; `sudo /opt/infra/monitoring/monitor.sh --status` | Webhook file exists with mode 600, host network, dedup state and two-run confirmation; never print the webhook |
| Low memory or disk | `free -h`; `df -h /`; `docker stats --no-stream`; `journalctl -k -g 'Out of memory' -n 20` | Load, swap/OOM events, log rotation and backup staging; do not delete volumes or snapshots without a recovery plan |

For a Standalone configuration check, `sudo /opt/infra/scripts/deploy.sh --check` validates required files without deploying. For registry errors in a trusted clone, `bash scripts/validation/validate-registry.sh` checks metadata and adapter references. Monitoring `--check` prints current issues without sending alerts; `--dry-run` has the same non-notifying behavior. On-host monitoring cannot send Discord alerts if the VPS or its Internet connection is down.
