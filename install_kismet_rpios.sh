#!/usr/bin/env bash
set -euo pipefail

# install_kismet_rpios.sh - Automates installing and configuring Kismet on Raspberry Pi OS 64-bit.
#
# Usage: sudo ./install_kismet_rpios.sh [--interface wlan1] [--skip-arch-check] \
#        [--enable-service] [--log-dir /path/to/logs]
#
# This script performs the following steps:
#   * Verifies it is running with administrative privileges.
#   * Optionally ensures the host architecture matches Raspberry Pi OS 64-bit (arm64).
#   * Adds the official Kismet APT repository (if not already present).
#   * Installs Kismet and related capture/logging tools (plus a compatibility symlink).
#   * Adds the invoking user to the "kismet" and "netdev" groups to allow capture access.
#   * Writes a minimal /etc/kismet/kismet_site.conf configured for the chosen Wi-Fi interface.
#   * Aligns log locations with the repository configuration (or a custom directory).
#   * Optionally enables the systemd Kismet service for automatic start at boot.
#
# The COMFAST CF-924AC V2 (Realtek 8812/8813 chipset) works with the linuxwifi capture
# source once its driver supports monitor mode. Ensure the appropriate kernel module is
# installed before running Kismet.

ARCH_CHECK=true
CAPTURE_INTERFACE="wlan1"
ENABLE_SERVICE=false
LOG_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interface)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --interface requires a value" >&2
                exit 1
            fi
            CAPTURE_INTERFACE="$1"
            ;;
        --skip-arch-check)
            ARCH_CHECK=false
            ;;
        --enable-service)
            ENABLE_SERVICE=true
            ;;
        --log-dir)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --log-dir requires a value" >&2
                exit 1
            fi
            LOG_DIR_OVERRIDE="$1"
            ;;
        -h|--help)
            sed -n '1,40p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ $(id -u) -ne 0 ]]; then
    echo "Please run this script with sudo or as root." >&2
    exit 1
fi

if $ARCH_CHECK; then
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" != "arm64" ]]; then
        echo "WARNING: Expected arm64 architecture for Raspberry Pi OS 64-bit but detected '$ARCH'." >&2
        echo "Re-run with --skip-arch-check if this is intentional." >&2
        exit 1
    fi
fi

if ! command -v lsb_release >/dev/null 2>&1; then
    apt-get update
    apt-get install -y lsb-release
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "raspbian" && "${ID:-}" != "debian" ]]; then
        echo "WARNING: Detected ID='${ID:-unknown}' in /etc/os-release; this script targets Raspberry Pi OS." >&2
    fi
fi

CODENAME=$(lsb_release -sc)
SUPPORTED_CODENAMES=(bullseye bookworm)
REPO_CODENAME="$CODENAME"
if [[ ! " ${SUPPORTED_CODENAMES[*]} " =~ " ${CODENAME} " ]]; then
    echo "WARNING: Raspberry Pi OS codename '$CODENAME' not explicitly supported. Falling back to 'bookworm'." >&2
    REPO_CODENAME="bookworm"
fi

apt-get update
apt-get install -y curl gnupg apt-transport-https ca-certificates

KEYRING=/usr/share/keyrings/kismet-archive-keyring.gpg
REPO_LIST=/etc/apt/sources.list.d/kismet.list

if [[ ! -f "$KEYRING" ]]; then
    echo "Importing Kismet repository signing key..."
    curl -fsSL https://www.kismetwireless.net/repos/kismet-release.gpg | gpg --dearmor -o "$KEYRING"
fi

echo "Configuring Kismet APT repository for '$REPO_CODENAME'..."
cat <<REPO | tee "$REPO_LIST" >/dev/null
deb [signed-by=$KEYRING] https://www.kismetwireless.net/repos/apt/release $REPO_CODENAME main
REPO

apt-get update
apt-get install -y kismet kismet-logtools libcap2-bin

if [[ ! -e /usr/local/bin/kismet && -x /usr/bin/kismet ]]; then
    echo "Creating compatibility symlink at /usr/local/bin/kismet for existing helper scripts..."
    ln -s /usr/bin/kismet /usr/local/bin/kismet
fi

TARGET_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "")}
if [[ -n "$TARGET_USER" ]]; then
    echo "Adding $TARGET_USER to kismet and netdev groups..."
    usermod -aG kismet "$TARGET_USER"
    usermod -aG netdev "$TARGET_USER"
fi

SITE_CONF=/etc/kismet/kismet_site.conf
if [[ -f "$SITE_CONF" ]]; then
    cp "$SITE_CONF" "${SITE_CONF}.bak.$(date +%Y%m%d%H%M%S)"
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.json"
PYTHON_BIN=$(command -v python3 || true)

determine_log_dir() {
    if [[ -n "$LOG_DIR_OVERRIDE" ]]; then
        printf '%s\n' "$LOG_DIR_OVERRIDE"
        return
    fi

    if [[ -n "$PYTHON_BIN" && -f "$CONFIG_FILE" ]]; then
        local parsed
        parsed=$("$PYTHON_BIN" - "$CONFIG_FILE" <<'PY'
import json, os, sys
config_path = sys.argv[1]
try:
    with open(config_path, 'r', encoding='utf-8') as handle:
        data = json.load(handle)
    raw_path = data.get('paths', {}).get('kismet_logs')
    if raw_path:
        # Remove wildcard suffixes (e.g., *.kismet)
        candidate = os.path.dirname(raw_path)
        if candidate:
            print(candidate)
except (OSError, json.JSONDecodeError):
    pass
PY
)
        if [[ -n "$parsed" ]]; then
            printf '%s\n' "$parsed"
            return
        fi
    fi

    if [[ -n "$TARGET_USER" ]]; then
        printf '/home/%s/kismet_logs\n' "$TARGET_USER"
    else
        printf '/var/log/kismet\n'
    fi
}

LOG_DIR=$(determine_log_dir)
LOG_PREFIX="$LOG_DIR/kismet"

if ! ip link show "$CAPTURE_INTERFACE" >/dev/null 2>&1; then
    echo "WARNING: Capture interface '$CAPTURE_INTERFACE' not found. Update --interface after connecting the adapter." >&2
fi

cat <<EOFCONF >"$SITE_CONF"
# Auto-generated by install_kismet_rpios.sh on $(date)
# Configure the COMFAST CF-924AC V2 (or other interface) for monitor mode capture.
# Adjust 'interface' if your adapter enumerates differently.
source=linuxwifi:name=cf-924ac-v2,interface=$CAPTURE_INTERFACE

# Optional: enable logging to the default directory and disable old log formats.
log_prefix=$LOG_PREFIX
write_interval=30
log_types=pcapng,pcapng-remote,kismetdb
EOFCONF

# Ensure the log directory exists with appropriate permissions.
install -d -m 0755 "$LOG_DIR"
chown kismet:kismet "$LOG_DIR"

# Enable or restart the Kismet service to apply settings when systemd is available.
if command -v systemctl >/dev/null 2>&1; then
    if $ENABLE_SERVICE; then
        systemctl enable kismet.service
    fi
    systemctl restart kismet.service
else
    echo "systemctl not available; skipping service enablement."
fi

# Set capture helper capabilities so Kismet can configure monitor mode.
if command -v kismet_cap_linux_wifi >/dev/null 2>&1; then
    setcap cap_net_admin,cap_net_raw+eip "$(command -v kismet_cap_linux_wifi)"
fi

echo "Kismet installation and configuration complete."
if [[ -n "$TARGET_USER" ]]; then
    echo "Log out and back in for group membership changes to take effect." 
fi

echo "Access the web UI at: http://localhost:2501"
