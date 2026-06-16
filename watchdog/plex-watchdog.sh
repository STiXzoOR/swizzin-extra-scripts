#!/bin/bash
# plex-watchdog.sh - Plex watchdog installer/manager
# STiXzoOR 2026
# Usage: plex-watchdog.sh [--install|--remove|--status|--reset]

set -euo pipefail

# ==============================================================================
# Constants
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_ENGINE="$SCRIPT_DIR/watchdog.sh"
GLOBAL_CONFIG_EXAMPLE="$SCRIPT_DIR/configs/watchdog.conf.example"
SERVICE_CONFIG_EXAMPLE="$SCRIPT_DIR/configs/plex-watchdog.conf.example"

INSTALL_DIR="/opt/swizzin-extras"
WATCHDOG_DEST="$INSTALL_DIR/watchdog.sh"
GLOBAL_CONFIG="$INSTALL_DIR/watchdog.conf"
CONFIG_DIR="$INSTALL_DIR/watchdog.d"
SERVICE_CONFIG="$CONFIG_DIR/plex.conf"

LOG_DIR="/var/log/watchdog"
STATE_DIR="/var/lib/watchdog"
LOG_FILE="$LOG_DIR/plex.log"
STATE_FILE="$STATE_DIR/plex.state"
LOCK_FILE="$STATE_DIR/plex.lock"

CRON_FILE="/etc/cron.d/plex-watchdog"
SERVICE_NAME="plexmediaserver"
APP_NAME="Plex"
HEALTH_URL="http://127.0.0.1:32400/identity"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_systemd_unit_written=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        }
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Helper Functions
# ==============================================================================

echo_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
echo_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
echo_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
echo_success() { echo -e "\033[0;32m[OK]\033[0m $1"; }

ask() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -rp "$prompt [Y/n]: " answer </dev/tty
        [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
    else
        read -rp "$prompt [y/N]: " answer </dev/tty
        [[ "$answer" =~ ^[Yy] ]]
    fi
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

_check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run as root"
        exit 1
    fi
}

_check_plex_installed() {
    if [[ ! -f "/install/.plex.lock" ]]; then
        echo_error "Plex is not installed. Install it first with: bash plex.sh"
        exit 1
    fi
}

_check_watchdog_files() {
    if [[ ! -f "$WATCHDOG_ENGINE" ]]; then
        echo_error "Watchdog engine not found: $WATCHDOG_ENGINE"
        exit 1
    fi

    if [[ ! -f "$GLOBAL_CONFIG_EXAMPLE" ]]; then
        echo_error "Global config example not found: $GLOBAL_CONFIG_EXAMPLE"
        exit 1
    fi

    if [[ ! -f "$SERVICE_CONFIG_EXAMPLE" ]]; then
        echo_error "Service config example not found: $SERVICE_CONFIG_EXAMPLE"
        exit 1
    fi
}

# ==============================================================================
# Installation
# ==============================================================================

_prompt_notifications() {
    echo ""
    echo_info "Configure notification settings (leave empty to skip)"
    echo ""

    read -rp "Discord webhook URL: " DISCORD_WEBHOOK </dev/tty
    read -rp "Pushover User Key: " PUSHOVER_USER </dev/tty
    read -rp "Pushover API Token: " PUSHOVER_TOKEN </dev/tty
    read -rp "Notifiarr API Key: " NOTIFIARR_API_KEY </dev/tty
    read -rp "Email address: " EMAIL_TO </dev/tty

    echo ""
}

_create_global_config() {
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        echo_info "Global config already exists, skipping"
        return
    fi

    echo_info "Creating global watchdog config..."

    _prompt_notifications

    cat >"$GLOBAL_CONFIG" <<EOF
# /opt/swizzin-extras/watchdog.conf - Global watchdog configuration

# Notifications
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
PUSHOVER_USER="${PUSHOVER_USER:-}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"
NOTIFIARR_API_KEY="${NOTIFIARR_API_KEY:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Default cooldown settings
DEFAULT_MAX_RESTARTS=3
DEFAULT_COOLDOWN_WINDOW=900
DEFAULT_HEALTH_TIMEOUT=10
EOF

    chmod 600 "$GLOBAL_CONFIG"
    echo_success "Global config created: $GLOBAL_CONFIG"
}

_create_service_config() {
    if [[ -f "$SERVICE_CONFIG" ]]; then
        echo_info "Plex watchdog config already exists, skipping"
        return
    fi

    echo_info "Creating Plex watchdog config..."

    mkdir -p "$CONFIG_DIR"

    cat >"$SERVICE_CONFIG" <<EOF
# Plex watchdog configuration

SERVICE_NAME="$SERVICE_NAME"
APP_NAME="$APP_NAME"
HEALTH_URL="$HEALTH_URL"
HEALTH_EXPECT="MediaContainer"
EOF

    echo_success "Service config created: $SERVICE_CONFIG"
}

_install_watchdog_engine() {
    echo_info "Installing watchdog engine..."

    mkdir -p "$INSTALL_DIR"
    cp "$WATCHDOG_ENGINE" "$WATCHDOG_DEST"
    chmod +x "$WATCHDOG_DEST"

    # Deploy shared notifications library alongside watchdog
    local notif_source="${SCRIPT_DIR}/../lib/notifications.sh"
    if [[ -f "$notif_source" ]]; then
        mkdir -p "$INSTALL_DIR/lib"
        cp "$notif_source" "$INSTALL_DIR/lib/notifications.sh"
        chmod 644 "$INSTALL_DIR/lib/notifications.sh"
        echo_success "Notifications library installed: $INSTALL_DIR/lib/notifications.sh"
    else
        echo_warn "Notifications library not found: $notif_source"
    fi

    echo_success "Watchdog engine installed: $WATCHDOG_DEST"
}

_create_directories() {
    echo_info "Creating log and state directories..."

    mkdir -p "$LOG_DIR"
    mkdir -p "$STATE_DIR"
    chmod 755 "$LOG_DIR"
    chmod 750 "$STATE_DIR"

    echo_success "Directories created"
}

_install_cron() {
    echo_info "Installing cron job..."

    cat >"$CRON_FILE" <<EOF
# Plex watchdog - runs every 2 minutes
*/2 * * * * root $WATCHDOG_DEST $SERVICE_CONFIG >> $LOG_FILE 2>&1
EOF

    chmod 644 "$CRON_FILE"
    echo_success "Cron job installed: $CRON_FILE"
}

_verify_setup() {
    echo_info "Verifying setup..."

    # Check if Plex service exists
    if ! systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        echo_warn "Service $SERVICE_NAME not found in systemd"
    fi

    # Check if Plex is running
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo_success "Service $SERVICE_NAME is running"
    else
        echo_warn "Service $SERVICE_NAME is not running"
    fi

    # Test health endpoint
    if curl -sf --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
        echo_success "Health endpoint is responding"
    else
        echo_warn "Health endpoint is not responding (service may not be running)"
    fi
}

_install() {
    echo_info "Installing Plex watchdog..."
    echo ""

    _check_plex_installed
    _check_watchdog_files

    _install_watchdog_engine
    _create_directories
    _create_global_config
    _create_service_config
    _install_cron
    _verify_setup

    echo ""
    echo_success "Plex watchdog installed successfully!"
    echo ""
    echo_info "Watchdog will check Plex every 2 minutes"
    echo_info "Logs: $LOG_FILE"
    echo_info "Edit notifications: $GLOBAL_CONFIG"
    echo ""
}

# ==============================================================================
# Removal
# ==============================================================================

_remove() {
    echo_info "Removing Plex watchdog..."

    # Remove cron job
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        echo_success "Removed cron job"
    fi

    # Remove service config
    if [[ -f "$SERVICE_CONFIG" ]]; then
        rm -f "$SERVICE_CONFIG"
        echo_success "Removed service config"
    fi

    # Remove state files
    rm -f "$STATE_FILE" "$LOCK_FILE"
    echo_success "Removed state files"

    # Ask about log file
    if [[ -f "$LOG_FILE" ]]; then
        if ask "Remove log file?"; then
            rm -f "$LOG_FILE"
            echo_success "Removed log file"
        fi
    fi

    # Check if other services use the watchdog
    local other_configs
    other_configs=$(find "$CONFIG_DIR" -name "*.conf" 2>/dev/null | wc -l)

    if [[ "$other_configs" -eq 0 ]]; then
        if ask "No other watchdog configs found. Remove watchdog engine and global config?"; then
            rm -f "$WATCHDOG_DEST" "$GLOBAL_CONFIG"
            rmdir "$CONFIG_DIR" 2>/dev/null || true
            echo_success "Removed watchdog engine and global config"
        fi
    fi

    echo ""
    echo_success "Plex watchdog removed"
}

# ==============================================================================
# Status
# ==============================================================================

_status() {
    echo ""
    echo "Plex Watchdog Status"
    echo "━━━━━━━━━━━━━━━━━━━━"

    # Check if installed
    if [[ ! -f "$SERVICE_CONFIG" ]]; then
        echo_error "Plex watchdog is not installed"
        echo_info "Run: $0 --install"
        exit 1
    fi

    # Service status
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "Service:     $SERVICE_NAME (\033[0;32mactive\033[0m)"
    else
        echo -e "Service:     $SERVICE_NAME (\033[0;31minactive\033[0m)"
    fi

    # Health check
    if curl -sf --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
        echo -e "Health:      $HEALTH_URL (\033[0;32mOK\033[0m)"
    else
        echo -e "Health:      $HEALTH_URL (\033[0;31mFAILED\033[0m)"
    fi

    # State info
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"

        local now
        now=$(date +%s)
        local window_restarts=0

        # Count restarts in current window
        if [[ -n "${RESTART_TIMESTAMPS:-}" ]]; then
            local cutoff=$((now - 900))
            IFS=',' read -ra timestamps <<<"$RESTART_TIMESTAMPS"
            for ts in "${timestamps[@]}"; do
                if [[ -n "$ts" && "$ts" -gt "$cutoff" ]]; then
                    ((window_restarts++)) || true
                fi
            done
        fi

        echo "Restarts:    $window_restarts/3 in current window"

        # Backoff status
        if [[ -n "${BACKOFF_UNTIL:-}" && "$now" -lt "${BACKOFF_UNTIL:-0}" ]]; then
            local backoff_time
            backoff_time=$(date -d "@$BACKOFF_UNTIL" '+%H:%M:%S')
            echo -e "State:       \033[0;31mbackoff until $backoff_time\033[0m"
        else
            echo -e "State:       \033[0;32mmonitoring\033[0m"
        fi
    else
        echo "Restarts:    0/3 in current window"
        echo -e "State:       \033[0;32mmonitoring\033[0m"
    fi

    # Last log entry
    if [[ -f "$LOG_FILE" ]]; then
        local last_check
        last_check=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -d']' -f1 | tr -d '[')
        if [[ -n "$last_check" ]]; then
            echo "Last check:  $last_check"
        fi
    fi

    # Cron status
    if [[ -f "$CRON_FILE" ]]; then
        echo -e "Cron:        \033[0;32menabled\033[0m (every 2 min)"
    else
        echo -e "Cron:        \033[0;31mdisabled\033[0m"
    fi

    echo ""
}

# ==============================================================================
# Reset
# ==============================================================================

_reset() {
    echo_info "Resetting Plex watchdog state..."

    if [[ -f "$STATE_FILE" ]]; then
        cat >"$STATE_FILE" <<EOF
RESTART_COUNT=0
RESTART_TIMESTAMPS=""
BACKOFF_UNTIL=""
EOF
        echo_success "State reset - watchdog will resume monitoring"
    else
        echo_info "No state file found, nothing to reset"
    fi
}

# ==============================================================================
# Usage
# ==============================================================================

_usage() {
    echo "Plex Watchdog Manager"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --install   Install Plex watchdog"
    echo "  --remove    Remove Plex watchdog"
    echo "  --status    Show current watchdog status"
    echo "  --reset     Clear backoff state, resume monitoring"
    echo "  -h, --help  Show this help message"
    echo ""
    echo "Without options, runs in interactive mode."
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo ""
    echo "Plex Watchdog Setup"
    echo "━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ -f "$SERVICE_CONFIG" ]]; then
        _status

        echo "What would you like to do?"
        echo "  1) Show status (already shown above)"
        echo "  2) Reset backoff state"
        echo "  3) Remove watchdog"
        echo "  4) Exit"
        echo ""
        read -rp "Choice [1-4]: " choice </dev/tty

        case "$choice" in
            1) _status ;;
            2) _reset ;;
            3) _remove ;;
            4) exit 0 ;;
            *)
                echo_error "Invalid choice"
                exit 1
                ;;
        esac
    else
        echo_info "Plex watchdog is not installed"
        echo ""

        if ask "Install Plex watchdog?" Y; then
            _install
        fi
    fi
}

# ==============================================================================
# Main
# ==============================================================================

_check_root

case "${1:-}" in
    --install)
        _install
        ;;
    --remove)
        _remove
        ;;
    --status)
        _status
        ;;
    --reset)
        _reset
        ;;
    -h | --help)
        _usage
        ;;
    "")
        _interactive
        ;;
    *)
        echo_error "Unknown option: $1"
        _usage
        exit 1
        ;;
esac
