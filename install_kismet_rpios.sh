#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install_kismet_rpios.sh
# ----------------------------------------------------------------------------
# Automatisiert die Installation und Konfiguration von Kismet auf Raspberry Pi OS (64-Bit)
# ----------------------------------------------------------------------------
# Features:
#  - Architekturprüfung (arm64)
#  - Import des offiziellen Kismet-Repos mit GPG-Verifikation
#  - Installation der Pakete (kismet, logtools, libcap2-bin)
#  - Sicheres Schreiben von /etc/kismet/kismet_site.conf
#  - Optionale Service-Aktivierung (--enable-service)
#  - Robust gegenüber Mehrfachausführung (idempotent)
#  - Unterstützt Flags: --interface, --skip-arch-check, --enable-service, --dry-run
# ============================================================================

ARCH_CHECK=true
CAPTURE_INTERFACE="wlan1"
ENABLE_SERVICE=false
DRY_RUN=false

# --- Argumente parsen --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interface)
            shift
            [[ $# -gt 0 ]] || { echo "ERROR: --interface benötigt Wert" >&2; exit 1; }
            CAPTURE_INTERFACE="$1"
            ;;
        --skip-arch-check) ARCH_CHECK=false ;;
        --enable-service)  ENABLE_SERVICE=true ;;
        --dry-run)         DRY_RUN=true ;;
        -h|--help)
            grep -E '^#' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Unbekanntes Argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# --- Root-Rechte prüfen ------------------------------------------------------
if [[ $(id -u) -ne 0 ]]; then
    echo "Bitte mit sudo oder als root ausführen." >&2
    exit 1
fi

# --- Architektur prüfen ------------------------------------------------------
if $ARCH_CHECK; then
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" != "arm64" ]]; then
        echo "WARNUNG: Erwartet arm64, gefunden '$ARCH'." >&2
        echo "Nutze --skip-arch-check, falls bewusst." >&2
        exit 1
    fi
fi

# --- Interface prüfen --------------------------------------------------------
if ! ip link show "$CAPTURE_INTERFACE" >/dev/null 2>&1; then
    echo "ERROR: Interface '$CAPTURE_INTERFACE' nicht gefunden." >&2
    exit 2
fi

# --- Dry-Run-Mode ------------------------------------------------------------
if $DRY_RUN; then
    echo "🔍 Dry-Run: keine Änderungen, nur Prüfung."
fi

# --- Apt-Setup ---------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
$DRY_RUN || apt-get update -y
$DRY_RUN || apt-get install -y curl gnupg apt-transport-https ca-certificates lsb-release libcap2-bin

# --- Repo vorbereiten --------------------------------------------------------
install -d -m 0755 /usr/share/keyrings
KEYRING=/usr/share/keyrings/kismet-archive-keyring.gpg
REPO_LIST=/etc/apt/sources.list.d/kismet.list
CODENAME=$(lsb_release -sc)
SUPPORTED_CODENAMES=(bullseye bookworm)
REPO_CODENAME="$CODENAME"
if [[ ! " ${SUPPORTED_CODENAMES[*]} " =~ " ${CODENAME} " ]]; then
    echo "WARN: Codename '$CODENAME' nicht offiziell unterstützt, nutze 'bookworm'."
    REPO_CODENAME="bookworm"
fi

if [[ ! -f "$KEYRING" ]]; then
    echo "Importiere GPG-Key für Kismet-Repository…"
    $DRY_RUN || curl -fsSL https://www.kismetwireless.net/repos/kismet-release.gpg | gpg --dearmor -o "$KEYRING"
fi

if ! grep -q "kismetwireless.net" "$REPO_LIST" 2>/dev/null; then
    echo "deb [signed-by=$KEYRING] https://www.kismetwireless.net/repos/apt/release $REPO_CODENAME main" | tee "$REPO_LIST" >/dev/null
fi

$DRY_RUN || apt-get update -y
$DRY_RUN || apt-get install -y kismet kismet-logtools

# --- Benutzergruppen ---------------------------------------------------------
TARGET_USER=${SUDO_USER:-${USER:-$(id -un)}}
if [[ -n "$TARGET_USER" ]]; then
    echo "Füge $TARGET_USER zu Gruppen 'kismet' und 'netdev' hinzu…"
    $DRY_RUN || usermod -aG kismet "$TARGET_USER"
    $DRY_RUN || usermod -aG netdev "$TARGET_USER"
fi

# --- Konfiguration -----------------------------------------------------------
SITE_CONF=/etc/kismet/kismet_site.conf
if [[ -f "$SITE_CONF" ]]; then
    cp "$SITE_CONF" "${SITE_CONF}.bak.$(date +%Y%m%d%H%M%S)"
fi

echo "Schreibe neue $SITE_CONF …"
$DRY_RUN || cat <<EOFCONF >"$SITE_CONF"
# Auto-generiert durch install_kismet_rpios.sh am $(date)
source=linuxwifi:name=cf-924ac-v2,interface=$CAPTURE_INTERFACE
log_prefix=/var/log/kismet/kismet
write_interval=30
log_types=pcapng,pcapng-remote,kismetdb
EOFCONF
$DRY_RUN || chmod 640 "$SITE_CONF"
$DRY_RUN || chown root:kismet "$SITE_CONF"

# --- Log-Verzeichnis ---------------------------------------------------------
install -d -m 0755 /var/log/kismet
$DRY_RUN || chown kismet:kismet /var/log/kismet

# --- Service-Handling --------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    if $ENABLE_SERVICE; then
        echo "Aktiviere und starte Kismet-Service…"
        $DRY_RUN || systemctl enable --now kismet.service
    else
        echo "Starte Kismet einmalig neu (Service bleibt deaktiviert)…"
        $DRY_RUN || systemctl restart kismet.service || true
    fi
else
    echo "Kein systemd vorhanden – Service-Handling übersprungen."
fi

# --- setcap für Capture-Helper ----------------------------------------------
if command -v kismet_cap_linux_wifi >/dev/null 2>&1; then
    echo "Setze capabilities für kismet_cap_linux_wifi…"
    $DRY_RUN || setcap cap_net_admin,cap_net_raw+eip "$(command -v kismet_cap_linux_wifi)" || true
fi

# --- Monitor-Mode-Check ------------------------------------------------------
if ! iw list 2>/dev/null | grep -A5 "Supported interface modes" | grep -q monitor; then
    echo "WARNUNG: Adapter unterstützt laut Treiber keinen Monitor-Mode!"
fi

# --- Abschlussmeldung --------------------------------------------------------
if $DRY_RUN; then
    echo "✅ Dry-Run abgeschlossen – keine Änderungen vorgenommen."
else
    echo "✅ Installation und Konfiguration abgeschlossen."
    echo "🔹 Web-UI: http://localhost:2501"
    echo "🔹 Log-Dir: /var/log/kismet"
    echo "🔹 Config:  $SITE_CONF"
    echo "Logge dich einmal aus/ein, damit Gruppenrechte greifen."
    logger -t install_kismet_rpios "Kismet installation completed for $CAPTURE_INTERFACE"
fi
