#!/bin/bash
set -euo pipefail
# ==============================================================================
# BINARY INSTALLER TEMPLATE
# ==============================================================================
# Template for installing single-binary applications to /usr/bin
# Examples: decypharr, notifiarr
#
# Usage: bash <appname>.sh [--update [--full] [--verbose]|--remove [--force]|--register-panel]
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, port, binary URL, icon, etc.)
# 2. Architecture mapping in _install_<app>()
# 3. Config file format in _install_<app>()
# 4. Systemd service options in _systemd_<app>()
# 5. Nginx location config in _nginx_<app>()
# ==============================================================================

# CUSTOMIZE: Replace "myapp" with your app name throughout this file
# Tip: Use sed 's/myapp/yourapp/g' and 's/Myapp/Yourapp/g'

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/nginx-utils.sh" 2>/dev/null || true

# ==============================================================================
# Panel Helper - Download and cache for panel integration
# ==============================================================================
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

# ==============================================================================
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_nginx_symlink_created=""
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_nginx_symlink_created" ]] && rm -f "$_nginx_symlink_created"
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
        _reload_nginx 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

# ==============================================================================
# App Configuration
# ==============================================================================
# CUSTOMIZE: Set all app-specific variables here

app_name="myapp"
app_pretty="Myapp"             # Display name (capitalized)
app_lockname="${app_name//-/}" # Lock file name (no hyphens)
app_baseurl="${app_name}"      # URL path (e.g., /myapp)

# Binary location
app_dir="/usr/bin"
app_binary="${app_name}"

# Port allocation
app_port=$(port 10000 12000)

# Dependencies (apt packages)
app_reqs=("curl")

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
# CUSTOMIZE: Set icon URL or use "placeholder" for default
app_icon_url="https://example.com/icon.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
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

# ==============================================================================
# Installation
# ==============================================================================
_install_myapp() {
    # Create config directory
    if [[ ! -d "$app_configdir" ]]; then
        mkdir -p "$app_configdir"
    fi
    chown -R "${user}:${user}" "$app_configdir"

    # Install dependencies
    apt_install "${app_reqs[@]}"

    echo_progress_start "Downloading release archive"

    local _tmp_download
    _tmp_download=$(mktemp "/tmp/${app_name}-XXXXXX.tar.gz")

    # CUSTOMIZE: Map architecture names to what the release uses
    case "$(_os_arch)" in
        "amd64") arch='x86_64' ;;
        "arm64") arch='arm64' ;;
        "armhf") arch='armv6' ;;
        *)
            echo_error "Architecture not supported"
            exit 1
            ;;
    esac

    # CUSTOMIZE: Set the GitHub API URL for releases
    local github_repo="owner/repo"
    latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep "${arch}" \
        | grep ".tar.gz" \
        | cut -d\" -f4) || {
        echo_error "Failed to query GitHub for latest version"
        exit 1
    }

    if ! curl -fsSL "$latest" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        exit 1
    fi
    echo_progress_done "Archive downloaded"

    echo_progress_start "Extracting archive"
    tar xf "$_tmp_download" --directory "${app_dir}/" >>"$log" 2>&1 || {
        echo_error "Failed to extract"
        exit 1
    }
    rm -f "$_tmp_download"
    chmod +x "${app_dir}/${app_binary}"
    echo_progress_done "Archive extracted"

    # CUSTOMIZE: Create default config file (skip if user has existing config)
    if [[ ! -f "${app_configdir}/config.json" ]]; then
        echo_progress_start "Creating default config"
        cat >"${app_configdir}/config.json" <<-CFG
			{
			  "port": ${app_port},
			  "url_base": "/${app_baseurl}/"
			}
		CFG
        echo_progress_done "Default config created"
    else
        echo_info "Existing config.json found, preserving user customizations"
    fi
    chown -R "${user}:${user}" "$app_configdir"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_myapp() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    _verbose "Creating backup directory: ${backup_dir}"
    mkdir -p "$backup_dir"

    if [[ -f "${app_dir}/${app_binary}" ]]; then
        _verbose "Backing up binary: ${app_dir}/${app_binary}"
        cp "${app_dir}/${app_binary}" "${backup_dir}/${app_binary}"
        _verbose "Backup complete ($(du -h "${backup_dir}/${app_binary}" | cut -f1))"
    else
        echo_error "Binary not found: ${app_dir}/${app_binary}"
        return 1
    fi
}

# ==============================================================================
# Rollback (restore from backup on failed update)
# ==============================================================================
_rollback_myapp() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    echo_error "Update failed, rolling back..."

    if [[ -f "${backup_dir}/${app_binary}" ]]; then
        _verbose "Restoring binary from backup"
        cp "${backup_dir}/${app_binary}" "${app_dir}/${app_binary}"
        chmod +x "${app_dir}/${app_binary}"

        _verbose "Restarting service"
        systemctl restart "$app_servicefile" 2>/dev/null || true

        echo_info "Rollback complete. Previous version restored."
    else
        echo_error "No backup found at ${backup_dir}"
        echo_info "Manual intervention required"
    fi

    # Clean up backup
    rm -rf "$backup_dir"
}

# ==============================================================================
# Update
# ==============================================================================
_update_myapp() {
    local full_reinstall="$1"

    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    # Full reinstall requested
    if [[ "$full_reinstall" == "true" ]]; then
        echo_info "Performing full reinstall of ${app_pretty}..."

        # Stop service
        echo_progress_start "Stopping service"
        systemctl stop "$app_servicefile" 2>/dev/null || true
        echo_progress_done "Service stopped"

        # Re-run full installation
        _install_myapp

        # Restart service
        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"

        echo_success "${app_pretty} reinstalled"
        exit 0
    fi

    # Binary-only update (default)
    echo_info "Updating ${app_pretty}..."

    # Create backup
    echo_progress_start "Backing up current binary"
    if ! _backup_myapp; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    # Stop service
    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    # Download new binary
    echo_progress_start "Downloading latest release"

    local _tmp_download
    _tmp_download=$(mktemp "/tmp/${app_name}-XXXXXX.tar.gz")

    # CUSTOMIZE: Map architecture names to what the release uses
    case "$(_os_arch)" in
        "amd64") arch='x86_64' ;;
        "arm64") arch='arm64' ;;
        "armhf") arch='armv6' ;;
        *)
            echo_error "Architecture not supported"
            _rollback_myapp
            exit 1
            ;;
    esac

    # CUSTOMIZE: Set the GitHub API URL for releases
    local github_repo="owner/repo"
    _verbose "Querying GitHub API: https://api.github.com/repos/${github_repo}/releases/latest"

    latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep "${arch}" \
        | grep ".tar.gz" \
        | cut -d\" -f4) || {
        echo_error "Failed to query GitHub for latest version"
        _rollback_myapp
        exit 1
    }

    _verbose "Downloading: ${latest}"
    if ! curl -fsSL "$latest" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        _rollback_myapp
        exit 1
    fi
    echo_progress_done "Downloaded"

    # Extract and replace binary
    echo_progress_start "Installing new binary"
    tar xf "$_tmp_download" --directory "${app_dir}/" >>"$log" 2>&1 || {
        echo_error "Failed to extract"
        _rollback_myapp
        exit 1
    }
    rm -f "$_tmp_download"
    chmod +x "${app_dir}/${app_binary}"
    echo_progress_done "Binary installed"

    # Restart service
    echo_progress_start "Restarting service"
    systemctl start "$app_servicefile"

    # Verify service started
    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_progress_done "Service running"
        _verbose "Service status: active"
    else
        echo_progress_done "Service may have issues"
        _rollback_myapp
        exit 1
    fi

    # Clean up backup
    rm -rf "/tmp/swizzin-update-backups/${app_name}"

    echo_success "${app_pretty} updated"
    exit 0
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_myapp() {
    local force="$1"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration
    if ask "Would you like to purge the configuration?" N; then
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

    # Remove binary
    echo_progress_start "Removing binary"
    rm -f "${app_dir}/${app_binary}"
    echo_progress_done "Binary removed"

    # Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/${app_name}.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

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

# ==============================================================================
# Systemd Service
# ==============================================================================
_systemd_myapp() {
    echo_progress_start "Installing systemd service"

    # CUSTOMIZE: Adjust ExecStart and other service options as needed
    cat >"/etc/systemd/system/${app_servicefile}" <<-EOF
		[Unit]
		Description=${app_pretty} Daemon
		After=syslog.target network.target

		[Service]
		User=${user}
		Group=${app_group}
		Type=simple
		ExecStart=${app_dir}/${app_binary} --config=${app_configdir}
		WorkingDirectory=${app_configdir}
		TimeoutStopSec=20
		KillMode=control-group
		Restart=on-failure
		RestartSec=5

		[Install]
		WantedBy=multi-user.target
	EOF

    systemctl daemon-reload
    systemctl enable --now "$app_servicefile" >>"$log" 2>&1
    echo_progress_done "Service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_myapp() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        # CUSTOMIZE: Adjust proxy settings as needed
        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port}/${app_baseurl}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect off;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /${app_baseurl}/api {
			    auth_basic off;
			    proxy_pass http://127.0.0.1:${app_port}/${app_baseurl}/api;
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} will run on port ${app_port}"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
    _remove_myapp "$2"
fi

# Handle --update flag
if [[ "$1" == "--update" ]]; then
    full_reinstall=false
    for arg in "$@"; do
        case "$arg" in
            --full) full_reinstall=true ;;
        esac
    done
    _update_myapp "$full_reinstall"
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
            "/${app_baseurl}" \
            "" \
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
    echo_error "${app_pretty} is already installed"
    exit 1
fi

# Set owner in swizdb
echo_info "Setting ${app_pretty} owner = ${user}"
swizdb set "${app_name}/owner" "$user"

# Run installation
_install_myapp
_systemd_myapp
_nginx_myapp

# Register with panel
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "$app_pretty" \
        "/${app_baseurl}" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

# Create lock file
touch "/install/.${app_lockname}.lock"

echo_success "${app_pretty} installed"
echo_info "Access at: https://your-server/${app_baseurl}/"
