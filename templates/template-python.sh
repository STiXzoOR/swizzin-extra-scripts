#!/bin/bash
set -euo pipefail
# ==============================================================================
# PYTHON/UV APP TEMPLATE
# ==============================================================================
# Template for installing Python applications using uv for dependency management
# Examples: byparr, huntarr, subgen
#
# Usage: bash <appname>.sh [--update [--full] [--verbose]|--remove [--force]|--register-panel]
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, port, repo URL, icon, etc.)
# 2. Environment config in _install_<app>()
# 3. Systemd service options in _systemd_<app>()
# 4. Nginx location config in _nginx_<app>() - optional for internal services
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
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
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
app_baseurl="${app_name}"      # URL path (e.g., /myapp) - optional

# Application directory (cloned repo)
app_dir="/opt/${app_name}"

# Port allocation
# CUSTOMIZE: Use fixed port if needed for compatibility (e.g., 8191 for FlareSolverr)
app_port=$(port 10000 12000)

# Dependencies (apt packages)
app_reqs=("curl" "git")

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
# CUSTOMIZE: Set icon URL or use "placeholder" for default
app_icon_url="https://example.com/icon.png"

# CUSTOMIZE: Set whether this app needs nginx (true/false)
app_needs_nginx=true

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
# UV Installation
# ==============================================================================
_install_uv() {
    # Install uv for the app user if not present
    if su - "$user" -c 'command -v uv >/dev/null 2>&1'; then
        echo_info "uv already installed for ${user}"
        return 0
    fi

    echo_progress_start "Installing uv for ${user}"
    su - "$user" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >>"$log" 2>&1 || {
        echo_error "Failed to install uv"
        exit 1
    }
    echo_progress_done "uv installed"
}

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

    # Install uv
    _install_uv

    echo_progress_start "Cloning ${app_pretty} repository"

    # Remove existing directory if present
    if [[ -d "$app_dir" ]]; then
        rm -rf "$app_dir"
    fi

    # CUSTOMIZE: Set the GitHub repository URL
    local github_repo="https://github.com/owner/repo.git"
    git clone "$github_repo" "$app_dir" >>"$log" 2>&1 || {
        echo_error "Failed to clone ${app_pretty} repository"
        exit 1
    }
    chown -R "${user}:${user}" "$app_dir"
    echo_progress_done "Repository cloned"

    echo_progress_start "Installing ${app_pretty} dependencies"
    su - "$user" -c "cd '${app_dir}' && uv sync" >>"$log" 2>&1 || {
        echo_error "Failed to install ${app_pretty} dependencies"
        exit 1
    }
    echo_progress_done "Dependencies installed"

    # CUSTOMIZE: Create environment config file (skip if user has existing config)
    if [[ ! -f "${app_configdir}/env.conf" ]]; then
        echo_progress_start "Creating environment config"
        cat >"${app_configdir}/env.conf" <<-EOF
			# ${app_pretty} environment configuration
			HOST=127.0.0.1
			PORT=${app_port}
		EOF
        echo_progress_done "Environment config created"
    else
        echo_info "Existing env.conf found, preserving user customizations"
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
_rollback_myapp() {
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

        # Remove existing directory
        rm -rf "$app_dir"

        # Re-run full installation
        _install_myapp

        # Restart service
        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"

        echo_success "${app_pretty} reinstalled"
        exit 0
    fi

    # Smart update (git pull + uv sync) - default
    echo_info "Updating ${app_pretty}..."

    # Create backup
    echo_progress_start "Backing up current installation"
    if ! _backup_myapp; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    # Stop service
    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    # Pull latest code
    echo_progress_start "Pulling latest code"
    _verbose "Running: git -C ${app_dir} pull"
    if ! su - "$user" -c "cd '${app_dir}' && git pull" >>"$log" 2>&1; then
        echo_error "Git pull failed"
        _rollback_myapp
        exit 1
    fi
    echo_progress_done "Code updated"

    # Update dependencies
    echo_progress_start "Updating dependencies"
    _verbose "Running: uv sync"
    if ! su - "$user" -c "cd '${app_dir}' && uv sync" >>"$log" 2>&1; then
        echo_error "Dependency update failed"
        _rollback_myapp
        exit 1
    fi
    echo_progress_done "Dependencies updated"

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

    # Remove application directory
    echo_progress_start "Removing application"
    rm -rf "$app_dir"
    echo_progress_done "Application removed"

    # Remove nginx config if exists
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

    # CUSTOMIZE: Adjust ExecStart for your app's entry point
    cat >"/etc/systemd/system/${app_servicefile}" <<-EOF
		[Unit]
		Description=${app_pretty} - Description of your app
		After=network.target

		[Service]
		Type=simple
		User=${user}
		Group=${app_group}
		WorkingDirectory=${app_dir}
		EnvironmentFile=${app_configdir}/env.conf
		ExecStart=/home/${user}/.local/bin/uv run python main.py
		Restart=on-failure
		RestartSec=10
		TimeoutStopSec=20

		[Install]
		WantedBy=multi-user.target
	EOF

    systemctl daemon-reload
    systemctl enable --now "$app_servicefile" >>"$log" 2>&1
    echo_progress_done "Service installed and enabled"
}

# ==============================================================================
# Nginx Configuration (Optional)
# ==============================================================================
_nginx_myapp() {
    # Skip if app doesn't need nginx
    if [[ "$app_needs_nginx" != "true" ]]; then
        echo_info "${app_pretty} running on http://127.0.0.1:${app_port}"
        return
    fi

    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        # CUSTOMIZE: Adjust proxy settings as needed
        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port}/;
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
			    proxy_pass http://127.0.0.1:${app_port}/api;
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} running on http://127.0.0.1:${app_port}"
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
        if [[ "$app_needs_nginx" == "true" ]]; then
            panel_register_app \
                "$app_name" \
                "$app_pretty" \
                "/${app_baseurl}" \
                "" \
                "$app_name" \
                "$app_icon_name" \
                "$app_icon_url" \
                "true"
        else
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
    if [[ "$app_needs_nginx" == "true" ]]; then
        # App with nginx - use baseurl
        panel_register_app \
            "$app_name" \
            "$app_pretty" \
            "/${app_baseurl}" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    else
        # Internal service - use urloverride
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
fi

# Create lock file
touch "/install/.${app_lockname}.lock"

echo_success "${app_pretty} installed"
if [[ "$app_needs_nginx" == "true" ]]; then
    echo_info "Access at: https://your-server/${app_baseurl}/"
else
    echo_info "Running on: http://127.0.0.1:${app_port}"
fi
