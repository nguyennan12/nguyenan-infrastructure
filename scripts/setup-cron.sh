#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/infra/backup"

test -x "$BACKUP_DIR/backup-all.sh"
test -x "$BACKUP_DIR/maintenance.sh"

cat > /etc/cron.d/infra-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 2 * * * root /opt/infra/backup/backup-all.sh >> /opt/infra/backup/backup.log 2>&1
0 5 * * 0 root /opt/infra/backup/maintenance.sh >> /opt/infra/backup/maintenance.log 2>&1
EOF

chmod 644 /etc/cron.d/infra-backup

systemctl enable --now cron

echo "Backup cron setup completed."