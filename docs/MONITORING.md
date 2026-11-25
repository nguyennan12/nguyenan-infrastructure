# Optional lightweight monitoring

[Quick Start](QUICKSTART.md) · [Configuration](CONFIGURATION.md) · [Troubleshooting](TROUBLESHOOTING.md)

The monitor runs as a root oneshot systemd service every five minutes. It does not manage containers. It reads the enabled stack containers and service health hooks from the installed registries. Host defaults: CPU above 90% for three runs, available RAM below 100 MiB, swap above 80%, root disk above 85%. TLS probes run once daily, warning 14 days before expiration. Backup success must be within 26 hours; GitOps sync status must be updated within one hour. Standalone does not evaluate GitOps status. Alerts require two failing runs (three for CPU) and recovery requires two healthy runs. Delivered incidents are not repeated for six hours.

The webhook must already be at `/opt/infra/monitoring/.discord-webhook`, root owned and mode 600. Create it through a private terminal or secret transfer; do not include its URL in shell arguments, documentation, Git or logs. The setup command refuses to enable the timer without it and does not overwrite it.

TLS checks cover enabled PostgreSQL (`postgres.<domain>:6433`, STARTTLS), Redis (`redis.<domain>:6380`, TLS) and MinIO (`minio.<domain>:443`, HTTPS). The root domain is not probed by default; set `MONITOR_ROOT_TLS=1` in the monitor service environment only when the root domain intentionally serves HTTPS.

From a trusted checkout on the target host, install the optional unit and scripts:

```bash
sudo bash /opt/infra/repository/scripts/monitoring/setup-monitoring.sh
sudo /opt/infra/monitoring/monitor.sh --check
sudo /opt/infra/monitoring/monitor.sh --test-notification
sudo systemctl list-timers infra-monitor.timer
sudo journalctl -u infra-monitor.service -n 30 --no-pager
sudo /opt/infra/monitoring/monitor.sh --status
```

`--check` and `--dry-run` evaluate conditions without sending or changing incident state. `--test-notification` sends a simulated warning and recovery. Do not copy the webhook into command arguments or logs. The encrypted infrastructure backup includes the webhook and systemd unit references when present; recovery preserves an existing webhook and does not enable the timer. Monitoring state and transient locks are not restored. On-host monitoring cannot notify Discord if the whole VPS or its Internet connection is unavailable.

Incident counters and delivery state are under `/opt/infra/state/monitoring/`; a notification is marked delivered only after Discord accepts it. Normal incidents need two consecutive failing checks (CPU needs three), recovery needs two healthy checks and reminders are delayed six hours. A failed Discord request is retried on later timer runs. `sudo journalctl -u infra-monitor.service -n 50 --no-pager` shows run errors without printing the webhook. The backup marker is `/opt/infra/state/backup-status`; GitOps status is `/opt/infra/state/sync-status`. Monitoring does not repair or restart services.
