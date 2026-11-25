#!/usr/bin/env bash

set -euo pipefail

echo "Setting up Cockpit..."

apt-get update
apt-get install -y cockpit

systemctl enable --now cockpit.socket

echo "Cockpit setup completed."