#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
PLAN_ONLY=false
[ "${1:-}" = "--plan" ] && PLAN_ONLY=true

source "$SCRIPT_DIR/lib/common.sh"

prompt_yes_no() {
    local prompt="$1"
    local default_yes="$2"
    local answer

    if [ "$default_yes" = "true" ]; then
        read -r -p "$prompt [Y/n] " answer
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N] " answer
        answer="${answer:-n}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

echo "===== Infrastructure Setup ====="
echo
echo "Installation type:"
echo "  1. Fresh installation"
echo "  2. Restore preparation"
read -r -p "Selection: " INSTALL_SELECTION
case "$INSTALL_SELECTION" in
    1) INSTALL_TYPE=fresh ;;
    2) INSTALL_TYPE=restore ;;
    *) echo "Invalid installation type." >&2; exit 1 ;;
esac

read -r -p "Infrastructure domain: " INSTALL_DOMAIN
validate_domain "$INSTALL_DOMAIN"

if [ "$INSTALL_DOMAIN" = "example.com" ]; then
    prompt_yes_no "example.com is reserved for documentation. Continue for testing?" false || exit 1
fi

echo
echo "Deployment mode:"
echo "  1. Standalone (Docker Compose)"
echo "  2. GitOps (Dockhand)"
read -r -p "Selection: " MODE_SELECTION
case "$MODE_SELECTION" in
    1) INSTALL_MODE=standalone ;;
    2) INSTALL_MODE=gitops ;;
    *) echo "Invalid deployment mode." >&2; exit 1 ;;
esac

if prompt_yes_no "Install Cockpit?" true; then
    INSTALL_COCKPIT=true
else
    INSTALL_COCKPIT=false
fi

if [ "$INSTALL_TYPE" = "fresh" ]; then
    BACKUP_PROMPT="Configure automated backup?"
else
    BACKUP_PROMPT="Configure access to an existing backup repository?"
fi

if prompt_yes_no "$BACKUP_PROMPT" true; then
    CONFIGURE_BACKUP=true
else
    CONFIGURE_BACKUP=false
fi

echo
echo "===== Installation Plan ====="
echo "Type:             $INSTALL_TYPE"
echo "Domain:           $INSTALL_DOMAIN"
echo "Deployment mode:  $INSTALL_MODE"
echo "Cockpit:          $INSTALL_COCKPIT"
echo "Automated backup: $CONFIGURE_BACKUP"
if [ "$INSTALL_TYPE" = "restore" ]; then
    echo "Services:         not started during restore preparation"
fi
echo "==============================="

prompt_yes_no "Confirm installation?" true || {
    echo "Installation cancelled."
    exit 1
}

if $PLAN_ONLY; then
    echo "Plan validation completed; no system changes were made."
    exit 0
fi

require_root
. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo "This bootstrap requires Ubuntu 24.04." >&2
    exit 1
fi

if command -v docker >/dev/null 2>&1 && [ -n "$(docker ps -aq)" ]; then
    echo "Existing Docker containers detected. Bootstrap is for a fresh or isolated recovery VPS." >&2
    exit 1
fi

INFRA_CONFIG_PREEXISTED=false
DEPLOYMENT_CONFIG_PREEXISTED=false
[ -e "$INFRA_ROOT/infrastructure.env" ] && INFRA_CONFIG_PREEXISTED=true
[ -e "$INFRA_ROOT/deployment.env" ] && DEPLOYMENT_CONFIG_PREEXISTED=true

bash "$SCRIPT_DIR/setup-system.sh"
bash "$SCRIPT_DIR/setup-docker.sh"
bash "$SCRIPT_DIR/setup-network.sh"
bash "$SCRIPT_DIR/setup-directories.sh"

if $INFRA_CONFIG_PREEXISTED; then
    EXISTING_DOMAIN="$(read_config_value "$INFRA_ROOT/infrastructure.env" INFRA_DOMAIN || true)"
    if [ "$EXISTING_DOMAIN" != "$INSTALL_DOMAIN" ]; then
        echo "Existing infrastructure.env does not match the requested domain; refusing to overwrite it." >&2
        exit 1
    fi
else
    printf 'INFRA_DOMAIN=%s\n' "$INSTALL_DOMAIN" > "$INFRA_ROOT/infrastructure.env"
    chmod 600 "$INFRA_ROOT/infrastructure.env"
    chown root:root "$INFRA_ROOT/infrastructure.env"
fi

if $DEPLOYMENT_CONFIG_PREEXISTED; then
    EXISTING_MODE="$(read_config_value "$INFRA_ROOT/deployment.env" DEPLOYMENT_MODE || true)"
    if [ "$EXISTING_MODE" != "$INSTALL_MODE" ]; then
        echo "Existing deployment.env has a different owner; refusing to overwrite it." >&2
        exit 1
    fi
else
    {
        printf 'DEPLOYMENT_MODE=%s\n' "$INSTALL_MODE"
        printf 'REPOSITORY_DIR=%s\n' "$REPO_DIR"
        printf 'STANDALONE_BRANCH=main\n'
    } > "$INFRA_ROOT/deployment.env"
    chmod 600 "$INFRA_ROOT/deployment.env"
    chown root:root "$INFRA_ROOT/deployment.env"
fi

if $INSTALL_COCKPIT; then
    bash "$SCRIPT_DIR/setup-cockpit.sh"
fi

if [ "$INSTALL_TYPE" = "fresh" ]; then
    bash "$SCRIPT_DIR/setup-secrets.sh"

    if [ "$INSTALL_MODE" = "standalone" ]; then
        REPO_DIR="$REPO_DIR" bash "$SCRIPT_DIR/deploy.sh"
    else
        bash "$SCRIPT_DIR/setup-dockhand.sh"
        echo "Register the four existing stack files in Dockhand using the documented project names."
        echo "Copy each required value from /opt/infra/secrets into the corresponding Dockhand stack environment."
    fi
else
    echo "Restore preparation completed without creating secrets, volumes, Dockhand, or stateful containers."
    echo "Extract and inspect backups before starting any service."
fi

if $CONFIGURE_BACKUP; then
    if [ "$INSTALL_TYPE" = "fresh" ]; then
        if bash "$SCRIPT_DIR/setup-backup.sh" --fresh; then
            bash "$SCRIPT_DIR/setup-cron.sh"
        else
            BACKUP_RESULT=$?
            if [ "$BACKUP_RESULT" -eq 10 ]; then
                echo "Backup configuration was skipped; no schedule was enabled."
            else
                exit "$BACKUP_RESULT"
            fi
        fi
    else
        if bash "$SCRIPT_DIR/setup-backup.sh" --restore; then
            echo "Restore preparation never enables backup schedules automatically."
        else
            BACKUP_RESULT=$?
            if [ "$BACKUP_RESULT" -eq 10 ]; then
                echo "Existing backup access setup was skipped."
            else
                exit "$BACKUP_RESULT"
            fi
        fi
    fi
fi

echo "===== Infrastructure setup completed ====="
echo "Manual checks remain: DNS records, firewall rules, TLS issuance and offsite backup authorization."
