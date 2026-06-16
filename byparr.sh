#!/bin/bash
# byparr installer
# STiXzoOR 2025
# Usage: bash byparr.sh [--remove [--force]] [--update [--full] [--verbose]] [--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
    # Prefer local repo copy (no network dependency, no supply chain risk)
    if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
        . "${SCRIPT_DIR}/panel_helpers.sh"
        return
    fi
    # Fallback to cached copy from a previous repo-based run
    if [[ -f "$PANEL_HELPER_CACHE" ]]; then
        . "$PANEL_HELPER_CACHE"
        return
    fi
    echo_info "panel_helpers.sh not found; skipping panel integration"
}

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

app_name="byparr"

# Get owner from swizdb (needed for both install and remove)
if ! BYPARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    BYPARR_OWNER="$(_get_master_username)"
fi
user="$BYPARR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=8191
app_reqs=("curl" "git")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/byparr.png"

if [ ! -d "$swiz_configdir" ]; then
    mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

_install_uv() {
    # Install uv for the app user if not present
    if su - "$user" -c 'command -v uv >/dev/null 2>&1'; then
        echo_info "uv already installed for $user"
        return 0
    fi

    echo_progress_start "Installing uv for $user"
    su - "$user" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >>"$log" 2>&1 || {
        echo_error "Failed to install uv"
        exit 1
    }
    echo_progress_done "uv installed"
}

_install_byparr() {
    if [ ! -d "$app_configdir" ]; then
        mkdir -p "$app_configdir"
    fi
    chown -R "$user":"$user" "$app_configdir"

    apt_install "${app_reqs[@]}"

    _install_uv

    echo_progress_start "Cloning ${app_name^} repository"

    if [ -d "$app_dir" ]; then
        rm -rf "$app_dir"
    fi

    git clone https://github.com/ThePhaseless/Byparr.git "$app_dir" >>"$log" 2>&1 || {
        echo_error "Failed to clone ${app_name^} repository"
        exit 1
    }
    chown -R "$user":"$user" "$app_dir"
    echo_progress_done "Repository cloned"

    echo_progress_start "Installing ${app_name^} dependencies"
    su - "$user" -c "cd '$app_dir' && uv sync" >>"$log" 2>&1 || {
        echo_error "Failed to install ${app_name^} dependencies"
        exit 1
    }
    echo_progress_done "Dependencies installed"

    # Create env file
    cat >"$app_configdir/env.conf" <<EOF
# Byparr environment
HOST=127.0.0.1
PORT=$app_port
EOF

    chown -R "$user":"$user" "$app_configdir"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_byparr() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    _verbose "Creating backup directory: ${backup_dir}"
    mkdir -p "$backup_dir"

    if [[ -d "$app_dir" ]]; then
        _verbose "Backing up application directory: ${app_dir}"
        cp -r "$app_dir" "${backup_dir}/app"
        _verbose "Backup complete ($(du -sh "${backup_dir}/app" | cut -f1))"
    else
        echo_error "Application directory not found: ${app_dir}"
        return 1
    fi
}

# ==============================================================================
# Rollback (restore from backup on failed update)
# ==============================================================================
_rollback_byparr() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    echo_error "Update failed, rolling back..."

    if [[ -d "${backup_dir}/app" ]]; then
        _verbose "Restoring application from backup"
        rm -rf "$app_dir"
        cp -r "${backup_dir}/app" "$app_dir"
        chown -R "${user}:${user}" "$app_dir"

        _verbose "Restarting service"
        systemctl restart "$app_servicefile" 2>/dev/null || true

        echo_info "Rollback complete. Previous version restored."
    else
        echo_error "No backup found at ${backup_dir}"
        echo_info "Manual intervention required"
    fi

    rm -rf "$backup_dir"
}

# ==============================================================================
# Update
# ==============================================================================
_update_byparr() {
    local full_reinstall="$1"

    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi

    # Full reinstall
    if [[ "$full_reinstall" == "true" ]]; then
        echo_info "Performing full reinstall of ${app_name^}..."
        echo_progress_start "Stopping service"
        systemctl stop "$app_servicefile" 2>/dev/null || true
        echo_progress_done "Service stopped"

        rm -rf "$app_dir"
        _install_byparr

        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"
        echo_success "${app_name^} reinstalled"
        exit 0
    fi

    # Smart update (git pull + uv sync)
    echo_info "Updating ${app_name^}..."

    echo_progress_start "Backing up current installation"
    if ! _backup_byparr; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Pulling latest code"
    _verbose "Running: git -C ${app_dir} pull"
    if ! su - "$user" -c "cd '${app_dir}' && git pull" >>"$log" 2>&1; then
        echo_error "Git pull failed"
        _rollback_byparr
        exit 1
    fi
    echo_progress_done "Code updated"

    echo_progress_start "Updating dependencies"
    _verbose "Running: uv sync"
    if ! su - "$user" -c "cd '${app_dir}' && uv sync" >>"$log" 2>&1; then
        echo_error "Dependency update failed"
        _rollback_byparr
        exit 1
    fi
    echo_progress_done "Dependencies updated"

    echo_progress_start "Restarting service"
    systemctl start "$app_servicefile"

    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_progress_done "Service running"
        _verbose "Service status: active"
    else
        echo_progress_done "Service may have issues"
        _rollback_byparr
        exit 1
    fi

    rm -rf "/tmp/swizzin-update-backups/${app_name}"
    echo_success "${app_name^} updated"
    exit 0
}

_remove_byparr() {
    local force="$1"
    if [ "$force" != "--force" ] && [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Ask about purging configuration
    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and disable service
    echo_progress_start "Stopping and disabling ${app_name^} service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/$app_servicefile"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove application directory
    echo_progress_start "Removing ${app_name^} application"
    rm -rf "$app_dir"
    echo_progress_done "Application removed"

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Remove config directory if purging
    if [ "$purgeconfig" = "true" ]; then
        echo_progress_start "Purging configuration files"
        rm -rf "$app_configdir"
        echo_progress_done "Configuration purged"
        # Remove swizdb entry
        swizdb clear "$app_name/owner" 2>/dev/null || true
    else
        echo_info "Configuration files kept at: $app_configdir"
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
}

_systemd_byparr() {
    echo_progress_start "Installing Systemd service"

    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - FlareSolverr alternative using Camoufox
After=network.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_dir
EnvironmentFile=$app_configdir/env.conf
ExecStart=/home/${user}/.local/bin/uv run python main.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable --now -q "$app_servicefile"
    sleep 1
    echo_progress_done "${app_name^} service installed and enabled"
    echo_info "${app_name^} is running on http://127.0.0.1:$app_port"
}

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

# Handle --update flag
if [[ "$1" == "--update" ]]; then
    full_reinstall=false
    for arg in "$@"; do
        case "$arg" in
            --full) full_reinstall=true ;;
        esac
    done
    _update_byparr "$full_reinstall"
fi

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
    _remove_byparr "$2"
fi

# Handle --register-panel flag
if [[ "$1" == "--register-panel" ]]; then
    if [[ ! -f "/install/.$app_lockname.lock" ]]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "Byparr" \
            "" \
            "http://127.0.0.1:$app_port" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_name^}"
    else
        echo_error "Panel helper not available"
        exit 1
    fi
    exit 0
fi

# Check if already installed
if [ -f "/install/.$app_lockname.lock" ]; then
    echo_info "${app_name^} is already installed"
else
    # Check for conflicting FlareSolverr installation
    if [[ -f "/install/.flaresolverr.lock" ]]; then
        echo_warn "FlareSolverr is installed and uses the same port (8191)"
        echo_warn "Both services cannot run simultaneously"
        if ! ask "Would you like to remove FlareSolverr and continue with Byparr installation?" N; then
            echo_info "Installation cancelled"
            exit 0
        fi
        # Remove FlareSolverr
        echo_info "Removing FlareSolverr..."
        systemctl stop flaresolverr 2>/dev/null || true
        systemctl disable flaresolverr 2>/dev/null || true
        rm -f /etc/systemd/system/flaresolverr.service
        systemctl daemon-reload
        rm -rf /opt/flaresolverr
        rm -f /install/.flaresolverr.lock
        _load_panel_helper
        if command -v panel_unregister_app >/dev/null 2>&1; then
            panel_unregister_app "flaresolverr"
        fi
        echo_info "FlareSolverr removed"
    fi

    # Set owner for install
    if [ -n "$BYPARR_OWNER" ]; then
        echo_info "Setting ${app_name^} owner = $BYPARR_OWNER"
        swizdb set "$app_name/owner" "$BYPARR_OWNER"
    fi

    _install_byparr
    _systemd_byparr
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Byparr" \
        "" \
        "http://127.0.0.1:$app_port" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
