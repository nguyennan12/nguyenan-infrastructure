#!/usr/bin/env bash
set -euo pipefail

echo "[1/4] Setting up system..."

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    curl \
    wget \
    git \
    jq \
    ca-certificates \
    gnupg \
    unzip \
    cron \
    restic \
    rclone \
    unattended-upgrades

timedatectl set-timezone Asia/Ho_Chi_Minh

# Create 2GB swap if no swap exists
if [ "$(swapon --noheadings | wc -l)" -eq 0 ]; then
    if [ -e /swapfile ]; then
        echo "Existing swapfile found. Please check manually."
        exit 1
    fi

    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

echo "System setup completed."
