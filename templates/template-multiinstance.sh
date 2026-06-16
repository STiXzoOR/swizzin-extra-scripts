#!/bin/bash
set -euo pipefail
# ==============================================================================
# MULTI-INSTANCE MANAGER TEMPLATE
# ==============================================================================
# Template for managing multiple instances of an existing Swizzin app
# Examples: sonarr, radarr
#
# Usage: bash <appname>.sh [--add [name]|--remove [name] [--force]|--list|--register-panel]
#
# This script:
# - Installs base app via `box install <app>` if not present
# - Creates named instances (e.g., 4k, anime, kids) with separate configs
# - Each instance gets its own systemd service, nginx config, and panel entry
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, binary, port, branch)
# 2. Config XML format in _add_instance()
# 3. Systemd ExecStart in _add_instance()
# 4. Nginx proxy settings in _add_instance()
# ==============================================================================

# CUSTOMIZE: Replace "myapp" with your app name throughout this file
# Tip: Use sed 's/myapp/yourapp/g' and 's/Myapp/Yourapp/g'

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

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
# App Configuration
# ==============================================================================
# CUSTOMIZE: Set all app-specific variables here

app_name="myapp"
app_pretty="Myapp"            # Display name
app_lockname="myapp"          # Base app lock file name
app_binary="/opt/Myapp/Myapp" # Path to binary
app_base_port="8989"          # Base app's default port
app_branch="main"             # Config branch (e.g., main, master)

# User and paths
user=$(_get_master_username)
profiles_py="/opt/swizzin/core/custom/profiles.py"

# ==============================================================================
# Base App Panel Meta Override
# ==============================================================================
# Ensures base app has check_theD = False in panel
_ensure_base_panel_meta() {
    [[ -f /install/.panel.lock ]] || return 0

    mkdir -p "$(dirname "$profiles_py")"
    touch "$profiles_py"

    # Check if override class already exists
    if ! grep -q "class ${app_name}_meta(${app_name}_meta):" "$profiles_py" 2>/dev/null; then
        echo_progress_start "Adding base ${app_pretty} panel override"
        cat >>"$profiles_py" <<-PYTHON

			class ${app_name}_meta(${app_name}_meta):
			    systemd = "${app_name}"
			    check_theD = False
		PYTHON
        systemctl restart panel 2>/dev/null || true
        echo_progress_done
    fi
}

# ==============================================================================
# Instance Name Validation
# ==============================================================================
_validate_instance_name() {
    local name="$1"

    # Check not empty
    if [[ -z "$name" ]]; then
        echo_error "Instance name cannot be empty"
        return 1
    fi

    # Check alphanumeric only
    if [[ ! "$name" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo_error "Instance name must be alphanumeric only (a-z, 0-9)"
        return 1
    fi

    # Convert to lowercase
    name="${name,,}"

    # Check reserved words
    if [[ "$name" == "base" ]]; then
        echo_error "Instance name 'base' is reserved"
        return 1
    fi

    # Check if already exists (lock files use underscore for panel compatibility)
    if [[ -f "/install/.${app_name}_${name}.lock" ]]; then
        echo_error "Instance '${app_name}-${name}' already exists"
        return 1
    fi

    echo "$name"
    return 0
}

# ==============================================================================
# Instance Discovery
# ==============================================================================
_get_instances() {
    local instances=()
    # Lock files use underscore for panel compatibility
    for lock in /install/.${app_name}_*.lock; do
        [[ -f "$lock" ]] || continue
        local instance_name
        instance_name=$(basename "$lock" .lock)
        instance_name="${instance_name#.${app_name}_}"
        instances+=("$instance_name")
    done
    echo "${instances[@]}"
}

_get_instance_port() {
    local name="$1"
    local config_file="/home/${user}/.config/${app_name}-${name}/config.xml"
    if [[ -f "$config_file" ]]; then
        grep -oP '(?<=<Port>)[^<]+' "$config_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# ==============================================================================
# Add Instance
# ==============================================================================
_add_instance() {
    local name="$1"

    # Validate name
    local validated_name
    validated_name=$(_validate_instance_name "$name") || return 1
    name="$validated_name"

    local instance_name="${app_name}-${name}"
    local instance_lock="${app_name}_${name}" # Lock files use underscore for panel
    local config_dir="/home/${user}/.config/${instance_name}"
    local instance_port
    instance_port=$(port 10000 12000)

    echo_info "Creating instance: ${instance_name}"

    # Create config directory
    echo_progress_start "Creating config directory"
    mkdir -p "$config_dir"
    chown -R "${user}:${user}" "$config_dir"
    echo_progress_done

    # CUSTOMIZE: Create config file (skip if user has existing config)
    if [[ ! -f "${config_dir}/config.xml" ]]; then
        echo_progress_start "Generating configuration"
        cat >"${config_dir}/config.xml" <<-EOSC
			<Config>
			  <LogLevel>info</LogLevel>
			  <UpdateMechanism>BuiltIn</UpdateMechanism>
			  <Branch>${app_branch}</Branch>
			  <BindAddress>127.0.0.1</BindAddress>
			  <Port>${instance_port}</Port>
			  <SslPort>9898</SslPort>
			  <EnableSsl>False</EnableSsl>
			  <LaunchBrowser>False</LaunchBrowser>
			  <AuthenticationMethod>None</AuthenticationMethod>
			  <UrlBase>${instance_name}</UrlBase>
			  <UpdateAutomatically>False</UpdateAutomatically>
			</Config>
		EOSC
        echo_progress_done
    else
        echo_info "Existing config.xml found, preserving user customizations"
    fi
    chown "${user}:${user}" "${config_dir}/config.xml"

    # Create systemd service
    # CUSTOMIZE: Adjust ExecStart for your app's command line format
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/${instance_name}.service" <<-SERV
		[Unit]
		Description=${app_pretty} ${name^} Instance
		After=network.target

		[Service]
		User=${user}
		Group=${user}
		UMask=0002
		Type=simple
		ExecStart=${app_binary} -nobrowser -data=${config_dir}
		TimeoutStopSec=20
		KillMode=control-group
		Restart=on-failure

		[Install]
		WantedBy=multi-user.target
	SERV
    systemctl daemon-reload
    echo_progress_done

    # Create nginx config if nginx is installed
    # CUSTOMIZE: Adjust proxy settings for your app
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Installing nginx config"
        cat >"/etc/nginx/apps/${instance_name}.conf" <<-NGX
			location ^~ /${instance_name} {
			    proxy_pass http://127.0.0.1:${instance_port};
			    proxy_set_header Host \$proxy_host;
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

			location ^~ /${instance_name}/api {
			    auth_basic off;
			    proxy_pass http://127.0.0.1:${instance_port};
			}
		NGX
        _reload_nginx
        echo_progress_done
    fi

    # Add panel entry
    if [[ -f /install/.panel.lock ]]; then
        echo_progress_start "Adding panel entry"
        _load_panel_helper
        if command -v panel_register_app >/dev/null 2>&1; then
            panel_register_app "${instance_name//-/_}" "${app_pretty} ${name^}" "/${instance_name}" "" "${instance_name}" "${app_name}" "" "true"
        fi
        echo_progress_done
    fi

    # Enable and start service
    echo_progress_start "Starting ${instance_name} service"
    systemctl enable --now "${instance_name}.service" >>"$log" 2>&1
    echo_progress_done

    # Create lock file (underscore for panel compatibility)
    touch "/install/.${instance_lock}.lock"

    echo_success "${app_pretty} instance '${name}' installed"
    echo_info "Access at: https://your-server/${instance_name}/"
    echo_info "Port: ${instance_port}"
}

# ==============================================================================
# Remove Instance
# ==============================================================================
_remove_instance() {
    local name="$1"
    local force="$2"
    local instance_name="${app_name}-${name}"
    local instance_lock="${app_name}_${name}" # Lock files use underscore for panel

    if [[ ! -f "/install/.${instance_lock}.lock" ]]; then
        echo_error "Instance '${instance_name}' not found"
        return 1
    fi

    echo_info "Removing instance: ${instance_name}"

    # Stop and disable service
    echo_progress_start "Stopping service"
    systemctl stop "${instance_name}.service" 2>/dev/null || true
    systemctl disable "${instance_name}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${instance_name}.service"
    systemctl daemon-reload
    echo_progress_done

    # Remove nginx config
    if [[ -f "/etc/nginx/apps/${instance_name}.conf" ]]; then
        echo_progress_start "Removing nginx config"
        rm -f "/etc/nginx/apps/${instance_name}.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done
    fi

    # Remove panel entry
    if [[ -f /install/.panel.lock ]]; then
        echo_progress_start "Removing panel entry"
        _load_panel_helper
        if command -v panel_unregister_app >/dev/null 2>&1; then
            panel_unregister_app "${instance_name//-/_}"
        fi
        echo_progress_done
    fi

    # Purge config
    local config_dir="/home/${user}/.config/${instance_name}"
    if [[ -d "$config_dir" ]]; then
        if [[ "$force" == "--force" ]]; then
            echo_progress_start "Purging configuration"
            rm -rf "$config_dir"
            echo_progress_done
        elif ask "Would you like to purge the configuration directory?" N; then
            echo_progress_start "Purging configuration"
            rm -rf "$config_dir"
            echo_progress_done
        else
            echo_info "Configuration kept at: ${config_dir}"
        fi
    fi

    # Remove lock file
    rm -f "/install/.${instance_lock}.lock"

    echo_success "Instance '${name}' removed"
}

# ==============================================================================
# Interactive Removal
# ==============================================================================
_remove_interactive() {
    local force="$1"
    local instances
    read -ra instances <<<"$(_get_instances)"

    if [[ ${#instances[@]} -eq 0 ]]; then
        echo_info "No ${app_pretty} instances installed"
        return 0
    fi

    # Build whiptail options
    local options=()
    for instance in "${instances[@]}"; do
        local port
        port=$(_get_instance_port "$instance")
        options+=("$instance" "port ${port}" "OFF")
    done

    local selected
    selected=$(whiptail --title "${app_pretty} Instance Removal" \
        --checklist "Select instances to remove:" \
        20 60 10 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) || {
        echo_info "Removal cancelled"
        return 0
    }

    # Parse selected instances
    selected=$(echo "$selected" | tr -d '"')

    for instance in $selected; do
        _remove_instance "$instance" "$force"
    done
}

# ==============================================================================
# List Instances
# ==============================================================================
_list_instances() {
    echo ""
    echo "${app_pretty} Instances:"
    echo "─────────────────────────────"

    # Check base installation
    if [[ -f "/install/.${app_lockname}.lock" ]]; then
        echo "  ${app_name} (base)     - port ${app_base_port}"
    else
        echo "  ${app_name} (base)     - not installed"
    fi

    # List additional instances
    local instances
    read -ra instances <<<"$(_get_instances)"

    if [[ ${#instances[@]} -eq 0 ]]; then
        echo "  (no additional instances)"
    else
        for instance in "${instances[@]}"; do
            local port
            port=$(_get_instance_port "$instance")
            printf "  %-18s - port %s\n" "${app_name}-${instance}" "$port"
        done
    fi
    echo ""
}

# ==============================================================================
# Base App Installation
# ==============================================================================
_ensure_base_installed() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_info "${app_pretty} is not installed"
        if ask "Would you like to install ${app_pretty}?" Y; then
            box install "$app_name" || {
                echo_error "Failed to install ${app_pretty}"
                exit 1
            }
        else
            echo_info "Cannot add instances without base ${app_pretty}"
            exit 0
        fi
    fi

    # Ensure base app has panel meta override
    _ensure_base_panel_meta
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================
_preflight() {
    if [[ ! -f /install/.nginx.lock ]]; then
        echo_error "nginx is not installed. Please install nginx first."
        exit 1
    fi
}

# ==============================================================================
# Interactive Add Flow
# ==============================================================================
_add_interactive() {
    while true; do
        if ! ask "Would you like to add a ${app_pretty} instance?" Y; then
            break
        fi

        echo -n "Enter instance name (alphanumeric, e.g., 4k, anime, kids): "
        read -r instance_name

        _add_instance "$instance_name" || continue
    done
}

# ==============================================================================
# Main
# ==============================================================================
_preflight

case "${1:-}" in
    "--add")
        _ensure_base_installed
        if [[ -n "${2:-}" ]]; then
            _add_instance "$2"
        else
            echo -n "Enter instance name (alphanumeric, e.g., 4k, anime, kids): "
            read -r instance_name
            _add_instance "$instance_name"
        fi
        ;;
    "--remove")
        if [[ -n "${2:-}" && "${2:-}" != "--force" ]]; then
            _remove_instance "$2" "${3:-}"
        else
            _remove_interactive "${2:-}"
        fi
        ;;
    "--list")
        _list_instances
        ;;
    "--register-panel")
        read -ra instances <<<"$(_get_instances)"
        if [[ ${#instances[@]} -eq 0 ]]; then
            echo_info "No ${app_pretty} instances installed"
            exit 0
        fi
        _load_panel_helper
        if ! command -v panel_register_app >/dev/null 2>&1; then
            echo_error "Panel helper not available"
            exit 1
        fi
        for name in "${instances[@]}"; do
            instance_name="${app_name}-${name}"
            panel_register_app "${instance_name//-/_}" "${app_pretty} ${name^}" "/${instance_name}" "" "${instance_name}" "${app_name}" "" "true"
            echo_info "Registered: ${instance_name}"
        done
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for all ${app_pretty} instances"
        ;;
    "")
        _ensure_base_installed
        _add_interactive
        ;;
    *)
        echo "Usage: $0 [--add [name]|--remove [name] [--force]|--list|--register-panel]"
        echo ""
        echo "  (no args)              Install base if needed, then add instances"
        echo "  --add [name]           Add a new instance"
        echo "  --remove [name]        Remove instance(s)"
        echo "  --remove name --force  Remove instance without prompts"
        echo "  --list                 List all instances"
        echo "  --register-panel       Re-register all instances with panel"
        exit 1
        ;;
esac
