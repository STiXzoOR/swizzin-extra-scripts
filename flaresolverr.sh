#!/bin/bash
# flaresolverr installer
# STiXzoOR 2025
# Usage: bash flaresolverr.sh [--update [--full] [--verbose]|--remove [--force]] [--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# Panel Helper - Download and cache for panel integration
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

app_name="flaresolverr"
app_pretty="FlareSolverr"
app_lockname="${app_name//-/}"

# Binary location - FlareSolverr extracts to a directory
app_dir="/opt/flaresolverr"
app_binary="flaresolverr"

# Port - 8191 is the default FlareSolverr port
app_port=8191

# Dependencies
app_reqs=("curl" "xvfb")

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/flaresolverr.png"

# Get owner from swizdb or fall back to master user
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Config directories
swiz_configdir="/home/${user}/.config"
app_configdir="${swiz_configdir}/${app_pretty}"

# Ensure base config directory exists
if [[ ! -d "$swiz_configdir" ]]; then
    mkdir -p "$swiz_configdir"
fi
chown "${user}:${user}" "$swiz_configdir"

_install_flaresolverr() {
    # Create config directory
    if [[ ! -d "$app_configdir" ]]; then
        mkdir -p "$app_configdir"
    fi
    chown -R "${user}:${user}" "$app_configdir"

    # Install dependencies
    apt_install "${app_reqs[@]}"

    # Check architecture - FlareSolverr only supports x64
    case "$(_os_arch)" in
        "amd64") arch='linux_x64' ;;
        *)
            echo_error "FlareSolverr only supports amd64/x64 architecture"
            exit 1
            ;;
    esac

    echo_progress_start "Downloading FlareSolverr"

    local _tmp_download
    _tmp_download=$(mktemp /tmp/flaresolverr-XXXXXX.tar.gz)

    # Get latest release URL
    local github_repo="FlareSolverr/FlareSolverr"
    latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep "${arch}" \
        | grep ".tar.gz" \
        | cut -d\" -f4) || {
        echo_error "Failed to query GitHub for latest version"
        exit 1
    }

    if [[ -z "$latest" ]]; then
        echo_error "Could not find download URL for ${arch}"
        exit 1
    fi

    if ! curl -fsSL "$latest" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        exit 1
    fi
    echo_progress_done "Downloaded"

    echo_progress_start "Extracting archive"

    # Remove old installation if exists
    if [[ -d "$app_dir" ]]; then
        rm -rf "$app_dir"
    fi

    # Create directory and extract
    mkdir -p "$app_dir"
    tar xf "$_tmp_download" --strip-components=1 -C "$app_dir" >>"$log" 2>&1 || {
        echo_error "Failed to extract"
        exit 1
    }
    rm -f "$_tmp_download"
    chown -R "${user}:${user}" "$app_dir"
    chmod +x "${app_dir}/${app_binary}"
    echo_progress_done "Extracted"

    # Create environment config file
    echo_progress_start "Creating configuration"
    cat >"${app_configdir}/env.conf" <<-EOF
		# FlareSolverr Configuration
		# See: https://github.com/FlareSolverr/FlareSolverr#environment-variables

		# Server settings
		HOST=127.0.0.1
		PORT=${app_port}

		# Logging
		LOG_LEVEL=info
		LOG_HTML=false

		# Browser settings
		HEADLESS=true

		# Timeouts (in milliseconds)
		BROWSER_TIMEOUT=40000
		TEST_URL=https://www.google.com

		# TZ for proper timezone (uncomment and set if needed)
		# TZ=UTC
	EOF
    chown -R "${user}:${user}" "$app_configdir"
    echo_progress_done "Configuration created"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_flaresolverr() {
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
_rollback_flaresolverr() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    echo_error "Update failed, rolling back..."

    if [[ -d "${backup_dir}/app" ]]; then
        _verbose "Restoring application from backup"
        rm -rf "$app_dir"
        cp -r "${backup_dir}/app" "$app_dir"
        chmod +x "${app_dir}/${app_binary}"
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
_update_flaresolverr() {
    local full_reinstall="$1"

    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    # Full reinstall
    if [[ "$full_reinstall" == "true" ]]; then
        echo_info "Performing full reinstall of ${app_pretty}..."
        echo_progress_start "Stopping service"
        systemctl stop "$app_servicefile" 2>/dev/null || true
        echo_progress_done "Service stopped"

        _install_flaresolverr

        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"
        echo_success "${app_pretty} reinstalled"
        exit 0
    fi

    # Binary-only update (default)
    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Backing up current installation"
    if ! _backup_flaresolverr; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Downloading latest release"

    local _tmp_download
    _tmp_download=$(mktemp /tmp/flaresolverr-XXXXXX.tar.gz)

    # Check architecture - FlareSolverr only supports x64
    case "$(_os_arch)" in
        "amd64") arch='linux_x64' ;;
        *)
            echo_error "FlareSolverr only supports amd64/x64 architecture"
            _rollback_flaresolverr
            exit 1
            ;;
    esac

    local github_repo="FlareSolverr/FlareSolverr"
    _verbose "Querying GitHub API: https://api.github.com/repos/${github_repo}/releases/latest"

    latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep "${arch}" \
        | grep ".tar.gz" \
        | cut -d\" -f4) || {
        echo_error "Failed to query GitHub"
        _rollback_flaresolverr
        exit 1
    }

    if [[ -z "$latest" ]]; then
        echo_error "No matching release found"
        _rollback_flaresolverr
        exit 1
    fi

    _verbose "Downloading: ${latest}"
    if ! curl -fsSL "$latest" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        _rollback_flaresolverr
        exit 1
    fi
    echo_progress_done "Downloaded"

    echo_progress_start "Installing update"
    # Remove old installation but preserve config
    rm -rf "$app_dir"
    mkdir -p "$app_dir"
    if ! tar xf "$_tmp_download" --strip-components=1 -C "$app_dir" >>"$log" 2>&1; then
        echo_error "Extraction failed"
        rm -f "$_tmp_download"
        _rollback_flaresolverr
        exit 1
    fi
    rm -f "$_tmp_download"
    chown -R "${user}:${user}" "$app_dir"
    chmod +x "${app_dir}/${app_binary}"
    echo_progress_done "Installed"

    echo_progress_start "Restarting service"
    systemctl start "$app_servicefile"

    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_progress_done "Service running"
        _verbose "Service status: active"
    else
        echo_progress_done "Service may have issues"
        _rollback_flaresolverr
        exit 1
    fi

    rm -rf "/tmp/swizzin-update-backups/${app_name}"
    echo_success "${app_pretty} updated"
    exit 0
}

_remove_flaresolverr() {
    local force="$1"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration (skip if --force)
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and disable service
    echo_progress_start "Stopping and disabling service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove application directory
    echo_progress_start "Removing application"
    rm -rf "$app_dir"
    echo_progress_done "Application removed"

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Purge config if requested
    if [[ "$purgeconfig" == "true" ]]; then
        echo_progress_start "Purging configuration files"
        rm -rf "$app_configdir"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        echo_progress_done "Configuration purged"
    else
        echo_info "Configuration files kept at: ${app_configdir}"
    fi

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

_systemd_flaresolverr() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<-EOF
		[Unit]
		Description=FlareSolverr - Proxy server to bypass Cloudflare protection
		After=network.target

		[Service]
		Type=simple
		User=${user}
		Group=${app_group}
		WorkingDirectory=${app_dir}
		EnvironmentFile=${app_configdir}/env.conf
		ExecStart=${app_dir}/${app_binary}
		TimeoutStopSec=20
		KillMode=control-group
		Restart=on-failure
		RestartSec=5

		[Install]
		WantedBy=multi-user.target
	EOF

    systemctl daemon-reload
    systemctl enable --now "$app_servicefile" >>"$log" 2>&1
    sleep 2
    echo_progress_done "Service installed and enabled"
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
    _update_flaresolverr "$full_reinstall"
fi

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
    _remove_flaresolverr "$2"
fi

# Handle --register-panel flag
if [[ "$1" == "--register-panel" ]]; then
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "$app_pretty" \
            "" \
            "http://127.0.0.1:${app_port}" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_pretty}"
    else
        echo_error "Panel helper not available"
        exit 1
    fi
    exit 0
fi

# Check if already installed
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    # Check for conflicting Byparr installation
    if [[ -f "/install/.byparr.lock" ]]; then
        echo_warn "Byparr is installed and uses the same port (8191)"
        echo_warn "Both services cannot run simultaneously"
        if ! ask "Would you like to remove Byparr and continue with FlareSolverr installation?" N; then
            echo_info "Installation cancelled"
            exit 0
        fi
        # Remove Byparr
        echo_info "Removing Byparr..."
        systemctl stop byparr 2>/dev/null || true
        systemctl disable byparr 2>/dev/null || true
        rm -f /etc/systemd/system/byparr.service
        systemctl daemon-reload
        rm -rf /opt/byparr
        rm -f /install/.byparr.lock
        _load_panel_helper
        if command -v panel_unregister_app >/dev/null 2>&1; then
            panel_unregister_app "byparr"
        fi
        echo_info "Byparr removed"
    fi

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    # Run installation
    _install_flaresolverr
    _systemd_flaresolverr
fi

# Register with panel (no nginx - API-only service)
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "$app_pretty" \
        "" \
        "http://127.0.0.1:${app_port}" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

# Create lock file
touch "/install/.${app_lockname}.lock"

echo_success "${app_pretty} installed"
echo_info "FlareSolverr is running on http://127.0.0.1:${app_port}"
echo_info "Configure in Prowlarr/Jackett as FlareSolverr proxy: http://127.0.0.1:${app_port}"
