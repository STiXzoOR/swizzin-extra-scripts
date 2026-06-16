#!/bin/bash
set -euo pipefail
# cleanuparr installer
# STiXzoOR 2025
# Usage: bash cleanuparr.sh [--update [--full] [--verbose]|--remove [--force]] [--register-panel]

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
touch $log

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

app_name="cleanuparr"

# Get owner from swizdb (needed for both install and remove)
if ! CLEANUPARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    CLEANUPARR_OWNER="$(_get_master_username)"
fi
user="$CLEANUPARR_OWNER"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("unzip")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_binary="Cleanuparr"
app_configdir="$app_dir/config"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/cleanuparr.png"

_install_cleanuparr() {
    if [ ! -d "$app_dir" ]; then
        mkdir -p "$app_dir"
    fi
    if [ ! -d "$app_configdir" ]; then
        mkdir -p "$app_configdir"
    fi
    chown -R "$user":"$user" "$app_dir"

    apt_install "${app_reqs[@]}"

    echo_progress_start "Downloading release archive"

    local _tmp_download _tmp_extract
    _tmp_download=$(mktemp /tmp/cleanuparr-XXXXXX.zip)
    _tmp_extract=$(mktemp -d /tmp/cleanuparr-extract-XXXXXX)

    case "$(_os_arch)" in
        "amd64") arch='linux-amd64' ;;
        "arm64") arch="linux-arm64" ;;
        *)
            echo_error "Arch not supported"
            exit 1
            ;;
    esac

    latest=$(curl -sL https://api.github.com/repos/Cleanuparr/Cleanuparr/releases/latest | grep "browser_download_url" | grep "$arch" | grep ".zip" | cut -d \" -f4) || {
        echo_error "Failed to query GitHub for latest version"
        exit 1
    }

    if ! curl "$latest" -L -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed, exiting"
        exit 1
    fi
    echo_progress_done "Archive downloaded"

    echo_progress_start "Extracting archive"
    # Extract to temp location first (zip contains versioned subfolder)
    unzip -o "$_tmp_download" -d "$_tmp_extract" >>"$log" 2>&1 || {
        echo_error "Failed to extract"
        exit 1
    }
    rm -f "$_tmp_download"

    # Move contents from versioned subfolder to app_dir
    extracted_folder=$(find "$_tmp_extract" -maxdepth 1 -type d -name "Cleanuparr-*" | head -1)
    if [ -z "$extracted_folder" ]; then
        echo_error "Could not find extracted folder"
        exit 1
    fi
    # Move all files from extracted folder to app_dir (preserve config if exists)
    mv "$extracted_folder"/* "$app_dir/" >>"$log" 2>&1
    rm -rf "$_tmp_extract"
    echo_progress_done "Archive extracted"

    chmod +x "$app_dir/$app_binary"

    echo_progress_start "Creating default config"
    cat >"$app_configdir/cleanuparr.json" <<CFG
{
  "PORT": ${app_port},
  "BIND_ADDRESS": "127.0.0.1",
  "BASE_PATH": "/${app_baseurl}"
}
CFG

    chown -R "$user":"$user" "$app_dir"
    echo_progress_done "Default config created"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_cleanuparr() {
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
_rollback_cleanuparr() {
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

    rm -rf "$backup_dir"
}

# ==============================================================================
# Update
# ==============================================================================
_update_cleanuparr() {
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

        _install_cleanuparr

        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"
        echo_success "${app_name^} reinstalled"
        exit 0
    fi

    # Binary-only update (default)
    echo_info "Updating ${app_name^}..."

    echo_progress_start "Backing up current binary"
    if ! _backup_cleanuparr; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Downloading latest release"

    local _tmp_download _tmp_extract
    _tmp_download=$(mktemp /tmp/cleanuparr-XXXXXX.zip)
    _tmp_extract=$(mktemp -d /tmp/cleanuparr-extract-XXXXXX)

    case "$(_os_arch)" in
        "amd64") arch='linux-amd64' ;;
        "arm64") arch='linux-arm64' ;;
        *)
            echo_error "Architecture not supported"
            _rollback_cleanuparr
            exit 1
            ;;
    esac

    local github_repo="Cleanuparr/Cleanuparr"
    _verbose "Querying GitHub API: https://api.github.com/repos/${github_repo}/releases/latest"

    latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep "$arch" \
        | grep ".zip" \
        | cut -d\" -f4) || {
        echo_error "Failed to query GitHub"
        _rollback_cleanuparr
        exit 1
    }

    if [[ -z "$latest" ]]; then
        echo_error "No matching release found"
        _rollback_cleanuparr
        exit 1
    fi

    _verbose "Downloading: ${latest}"
    if ! curl -fsSL "$latest" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        _rollback_cleanuparr
        exit 1
    fi
    echo_progress_done "Downloaded"

    echo_progress_start "Installing update"
    # Extract to temp location first (zip contains versioned subfolder)
    if ! unzip -o "$_tmp_download" -d "$_tmp_extract" >>"$log" 2>&1; then
        echo_error "Extraction failed"
        rm -f "$_tmp_download"
        rm -rf "$_tmp_extract"
        _rollback_cleanuparr
        exit 1
    fi
    rm -f "$_tmp_download"

    # Move contents from versioned subfolder to app_dir
    extracted_folder=$(find "$_tmp_extract" -maxdepth 1 -type d -name "Cleanuparr-*" | head -1)
    if [[ -z "$extracted_folder" ]]; then
        echo_error "Could not find extracted folder"
        rm -rf "$_tmp_extract"
        _rollback_cleanuparr
        exit 1
    fi
    # Move binary from extracted folder (preserve config)
    mv "$extracted_folder/${app_binary}" "${app_dir}/${app_binary}" >>"$log" 2>&1
    rm -rf "$_tmp_extract"
    chmod +x "${app_dir}/${app_binary}"
    chown "${user}:${user}" "${app_dir}/${app_binary}"
    echo_progress_done "Installed"

    echo_progress_start "Restarting service"
    systemctl start "$app_servicefile"

    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_progress_done "Service running"
        _verbose "Service status: active"
    else
        echo_progress_done "Service may have issues"
        _rollback_cleanuparr
        exit 1
    fi

    rm -rf "/tmp/swizzin-update-backups/${app_name}"
    echo_success "${app_name^} updated"
    exit 0
}

_remove_cleanuparr() {
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

    # Remove binary/directory
    echo_progress_start "Removing ${app_name^} files"
    if [ "$purgeconfig" = "true" ]; then
        rm -rf "$app_dir"
        echo_progress_done "All files removed"
    else
        rm -f "$app_dir/$app_binary"
        echo_progress_done "Binary removed (config kept at $app_configdir)"
    fi

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

    # Remove swizdb entry
    if [ "$purgeconfig" = "true" ]; then
        swizdb clear "$app_name/owner" 2>/dev/null || true
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
}

_systemd_cleanuparr() {
    echo_progress_start "Installing Systemd service"
    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} Daemon
After=syslog.target network.target

[Service]
User=${user}
Group=${app_group}
Type=simple
WorkingDirectory=${app_dir}
ExecStart=${app_dir}/${app_binary}
TimeoutStopSec=20
KillMode=control-group
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable --now -q "$app_servicefile"
    sleep 1
    echo_progress_done "${app_name^} service installed and enabled"
}

_nginx_cleanuparr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_baseurl {
			  return 301 /$app_baseurl/;
			}

			location ^~ /$app_baseurl/ {
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/;
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

			location ^~ /$app_baseurl/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/api;
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
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
    _update_cleanuparr "$full_reinstall"
fi

# Handle --remove flag
if [ "${1:-}" = "--remove" ]; then
    _remove_cleanuparr "${2:-}"
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
            "Cleanuparr" \
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
if [ -f "/install/.$app_lockname.lock" ]; then
    echo_info "${app_name^} is already installed"
else
    # Set owner for install
    if [ -n "$CLEANUPARR_OWNER" ]; then
        echo_info "Setting ${app_name^} owner = $CLEANUPARR_OWNER"
        swizdb set "$app_name/owner" "$CLEANUPARR_OWNER"
    fi

    _install_cleanuparr
    _systemd_cleanuparr
    _nginx_cleanuparr
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Cleanuparr" \
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
