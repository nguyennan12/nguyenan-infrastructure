#!/usr/bin/env bash
set -euo pipefail
umask 077
[ "$EUID" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
install -d -m 700 /opt/infra/monitoring /opt/infra/state/monitoring
[ -s /opt/infra/monitoring/.discord-webhook ] || { echo 'Create /opt/infra/monitoring/.discord-webhook with mode 600 first.' >&2; exit 1; }
[ "$(stat -c '%a' /opt/infra/monitoring/.discord-webhook)" = 600 ] || { echo 'Webhook must have mode 600.' >&2; exit 1; }
for name in monitor checks notify; do
    install -m 700 "$ROOT/scripts/monitoring/$name.sh" "/opt/infra/monitoring/$name.sh"
done
install -m 644 "$ROOT/configs/systemd/infra-monitor.service" /etc/systemd/system/infra-monitor.service
install -m 644 "$ROOT/configs/systemd/infra-monitor.timer" /etc/systemd/system/infra-monitor.timer
systemctl daemon-reload
systemctl enable --now infra-monitor.timer
echo 'Monitoring timer enabled.'
