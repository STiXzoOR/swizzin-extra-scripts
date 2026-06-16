#!/bin/bash
set -euo pipefail
# huntarr installer
# STiXzoOR 2025
# Usage: bash huntarr.sh [--remove [--force]] [--update [--full] [--verbose]] [--register-panel]
#
# WARNING: USE AT YOUR OWN RISK
# Huntarr has known critical security vulnerabilities (disclosed Feb 2025):
#   - Unauthenticated API endpoints expose all connected *arr API keys in cleartext
#   - Unauthenticated 2FA enrollment allows full account takeover
#   - Unauthenticated setup reset (/api/setup/clear) allows owner replacement
#   - Zip Slip (arbitrary file write via uploads)
#   - Path traversal via backup_id (arbitrary directory deletion)
#   - X-Forwarded-For header spoofing bypasses local access restrictions
# The upstream repo has been deleted. These vulnerabilities are UNPATCHED.
# See: https://lemmy.world/post/43496203
#
# This installer applies auth to the API proxy path, but cannot fix
# vulnerabilities within Huntarr itself. Do NOT expose to untrusted networks.

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

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

app_name="huntarr"

# Get owner from swizdb (needed for both install and remove)
if ! HUNTARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    HUNTARR_OWNER="$(_get_master_username)"
fi
user="$HUNTARR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "git")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/huntarr.png"

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

_install_huntarr() {
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

    git clone https://github.com/plexguide/Huntarr.io.git "$app_dir" >>"$log" 2>&1 || {
        echo_error "Failed to clone ${app_name^} repository"
        exit 1
    }
    chown -R "$user":"$user" "$app_dir"
    echo_progress_done "Repository cloned"

    echo_progress_start "Installing ${app_name^} dependencies"

    # Create pyproject.toml for uv if only requirements.txt exists
    if [ -f "$app_dir/requirements.txt" ] && [ ! -f "$app_dir/pyproject.toml" ]; then
        # Build dependencies array from requirements.txt (strip comments, fix pyyaml pin)
        deps_array=$(grep -vE '^\s*#|^\s*$' "$app_dir/requirements.txt" | sed 's/\s*#.*//' | sed 's/pyyaml==6\.0$/pyyaml>=6.0.1/' | sed 's/.*/"&",/' | tr '\n' ' ' | sed 's/, $//')
        cat >"$app_dir/pyproject.toml" <<PYPROJ
[project]
name = "huntarr"
version = "0.0.0"
requires-python = ">=3.9,<3.13"
dependencies = [$deps_array]
PYPROJ
    fi

    su - "$user" -c "cd '$app_dir' && uv sync" >>"$log" 2>&1 || {
        echo_error "Failed to install ${app_name^} dependencies"
        exit 1
    }

    echo_progress_done "Dependencies installed"

    # Get system timezone
    system_tz="UTC"
    if [ -f /etc/timezone ]; then
        system_tz=$(cat /etc/timezone)
    elif [ -L /etc/localtime ]; then
        system_tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
    fi

    # Create env file
    cat >"$app_configdir/env.conf" <<EOF
# Huntarr environment
TZ=$system_tz
BASE_URL=/$app_baseurl
CONFIG_DIR=$app_configdir
EOF

    chown -R "$user":"$user" "$app_configdir"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_huntarr() {
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
_rollback_huntarr() {
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
_update_huntarr() {
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
        _install_huntarr

        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"
        echo_success "${app_name^} reinstalled"
        exit 0
    fi

    # Smart update (git pull + uv sync)
    echo_info "Updating ${app_name^}..."

    echo_progress_start "Backing up current installation"
    if ! _backup_huntarr; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Pulling latest code"
    _verbose "Running: git fetch + reset to origin/main"
    if ! su - "$user" -c "cd '${app_dir}' && git fetch origin && git reset --hard origin/main" >>"$log" 2>&1; then
        echo_error "Git pull failed"
        _rollback_huntarr
        exit 1
    fi
    echo_progress_done "Code updated"

    echo_progress_start "Updating dependencies"
    # Regenerate pyproject.toml from updated requirements.txt
    if [ -f "$app_dir/requirements.txt" ]; then
        deps_array=$(grep -vE '^\s*#|^\s*$' "$app_dir/requirements.txt" | sed 's/\s*#.*//' | sed 's/pyyaml==6\.0$/pyyaml>=6.0.1/' | sed 's/.*/"&",/' | tr '\n' ' ' | sed 's/, $//')
        cat >"$app_dir/pyproject.toml" <<PYPROJ
[project]
name = "huntarr"
version = "0.0.0"
requires-python = ">=3.9,<3.13"
dependencies = [$deps_array]
PYPROJ
        chown "$user":"$user" "$app_dir/pyproject.toml"
    fi
    _verbose "Running: uv sync"
    if ! su - "$user" -c "cd '${app_dir}' && uv sync" >>"$log" 2>&1; then
        echo_error "Dependency update failed"
        _rollback_huntarr
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
        _rollback_huntarr
        exit 1
    fi

    rm -rf "/tmp/swizzin-update-backups/${app_name}"
    echo_success "${app_name^} updated"
    exit 0
}

_remove_huntarr() {
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

    # Remove nginx config
    if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
        echo_progress_start "Removing nginx configuration"
        _remove_nginx_conf "$app_name"
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

_systemd_huntarr() {
    echo_progress_start "Installing Systemd service"

    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Automated media discovery for *arr apps
After=network.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_dir
EnvironmentFile=$app_configdir/env.conf
Environment=PORT=$app_port
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
}

_nginx_huntarr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_baseurl {
			  return 301 /$app_baseurl/;
			}

			location ^~ /$app_baseurl/ {
			    proxy_pass http://127.0.0.1:$app_port;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
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

			location ^~ /$app_baseurl/api {
			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			    proxy_pass http://127.0.0.1:$app_port;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_name^} will run on port $app_port"
    fi
}

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

# Handle --update flag
if [[ "${1:-}" == "--update" ]]; then
    full_reinstall=false
    for arg in "$@"; do
        case "$arg" in
            --full) full_reinstall=true ;;
        esac
    done
    _update_huntarr "$full_reinstall"
fi

# Handle --remove flag
if [ "${1:-}" = "--remove" ]; then
    _remove_huntarr "${2:-}"
fi

# Handle --register-panel flag
if [ "${1:-}" = "--register-panel" ]; then
    if [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "Huntarr" \
            "/$app_baseurl" \
            "" \
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
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_name^} is already installed"
else
    echo_warn "SECURITY WARNING: Huntarr has known critical vulnerabilities (unpatched)."
    echo_warn "API keys for all connected *arr apps may be at risk."
    echo_warn "The upstream repository has been deleted. USE AT YOUR OWN RISK."
    if ! ask "Do you still want to install Huntarr?" N; then
        echo_info "Installation cancelled."
        exit 0
    fi

    # Set owner for install
    if [[ -n "$HUNTARR_OWNER" ]]; then
        echo_info "Setting ${app_name^} owner = $HUNTARR_OWNER"
        swizdb set "$app_name/owner" "$HUNTARR_OWNER"
    fi

    _install_huntarr
    _systemd_huntarr
    _nginx_huntarr
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Huntarr" \
        "/$app_baseurl" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
echo_info "Access at: https://your-server/${app_baseurl}/"
echo_info "Port: ${app_port}"
