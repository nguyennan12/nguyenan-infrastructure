# Optional lightweight monitoring

The monitor runs as a root oneshot systemd service every five minutes. It does not manage containers. It reads the enabled stack containers and service health hooks from the installed registries. Host defaults: CPU above 90% for three runs, available RAM below 100 MiB, swap above 80%, root disk above 85%. TLS probes run once daily, warning 14 days before expiration. Backup success must be within 26 hours; GitOps sync status must be updated within one hour. Standalone does not evaluate GitOps status. Alerts require two failing runs (three for CPU) and recovery requires two healthy runs. Delivered incidents are not repeated for six hours.

The existing webhook must already be at `/opt/infra/monitoring/.discord-webhook`, root owned and mode 600. The setup command preserves it:

```bash
sudo bash /opt/infra/repository/scripts/monitoring/setup-monitoring.sh
sudo /opt/infra/monitoring/monitor.sh --check
sudo /opt/infra/monitoring/monitor.sh --test-notification
sudo systemctl list-timers infra-monitor.timer
sudo journalctl -u infra-monitor.service -n 30 --no-pager
sudo /opt/infra/monitoring/monitor.sh --status
```

`--check` and `--dry-run` evaluate conditions without sending or changing incident state. `--test-notification` sends a simulated warning and recovery. Do not copy the webhook into command arguments or logs. The encrypted infrastructure backup includes the webhook and systemd unit references when present; recovery preserves an existing webhook and does not enable the timer. Monitoring state and transient locks are not restored. On-host monitoring cannot notify Discord if the whole VPS or its Internet connection is unavailable.
