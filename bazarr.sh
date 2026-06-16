#!/bin/bash
set -euo pipefail
# bazarr multi-instance installer
# STiXzoOR 2025
# Usage: bash bazarr.sh [--add|--remove [name] [--force]|--list|--register-panel|--migrate]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

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

app_name="bazarr"
app_python="/opt/.venv/bazarr/bin/python3"
app_script="/opt/bazarr/bazarr.py"
app_base_port="6767"
app_pretty="Bazarr"
app_lockname="bazarr"

user=$(_get_master_username)
profiles_py="/opt/swizzin/core/custom/profiles.py"

# Ensure base app has panel meta override with check_theD = False
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

# Deploy patched subtitle providers (survives Bazarr auto-updates)
_deploy_provider_patches() {
    local hook_script="/opt/swizzin-scripts/hooks/bazarr-apply-patches.sh"
    local overlay_dir="/opt/swizzin-scripts/overlays/bazarr/providers"
    local target_dir="/opt/bazarr/custom_libs/subliminal_patch/providers"

    # Ensure overlay directory exists with provider fixes
    if [[ ! -d "$overlay_dir" ]]; then
        echo_info "No provider overlay directory found, skipping patches"
        return 0
    fi

    # Make hook script executable
    [[ -f "$hook_script" ]] && chmod +x "$hook_script"

    # Add ExecStartPre to base service if not present
    local base_service="/etc/systemd/system/${app_name}.service"
    if [[ -f "$base_service" ]] && ! grep -q "bazarr-apply-patches" "$base_service" 2>/dev/null; then
        sed -i "/\[Service\]/a ExecStartPre=+${hook_script}" "$base_service"
    fi

    # Add ExecStartPre to all instance services
    for service_file in /etc/systemd/system/${app_name}-*.service; do
        [[ -f "$service_file" ]] || continue
        if ! grep -q "bazarr-apply-patches" "$service_file" 2>/dev/null; then
            sed -i "/\[Service\]/a ExecStartPre=+${hook_script}" "$service_file"
        fi
    done

    systemctl daemon-reload

    # Apply patches immediately
    if [[ -d "$target_dir" ]] && [[ -f "$hook_script" ]]; then
        bash "$hook_script"
        echo_info "Provider patches applied"
    fi
}

# Validate instance name (alphanumeric only, lowercase)
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

# Get list of installed instances
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

# Get port from instance config (supports both YAML and legacy INI)
_get_instance_port() {
    local name="$1"
    local config_dir="/home/${user}/.config/${app_name}-${name}/config"

    # Try YAML first (new format)
    if [[ -f "${config_dir}/config.yaml" ]]; then
        grep -oP '^\s*port:\s*\K\d+' "${config_dir}/config.yaml" 2>/dev/null || echo "unknown"
    # Fall back to INI (legacy format)
    elif [[ -f "${config_dir}/config.ini" ]]; then
        grep -oP '(?<=^port = )\d+' "${config_dir}/config.ini" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Add a new instance
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

    # Create config directory structure
    echo_progress_start "Creating config directory"
    mkdir -p "${config_dir}/config"
    chown -R "${user}:${user}" "$config_dir"
    echo_progress_done

    # Create config.yaml (skip if user has existing config)
    if [[ ! -f "${config_dir}/config/config.yaml" ]]; then
        echo_progress_start "Generating configuration"
        cat >"${config_dir}/config/config.yaml" <<-EOSC
			general:
			  ip: 127.0.0.1
			  port: ${instance_port}
			  base_url: /${instance_name}
			  single_language: false
			  use_embedded_subs: true
			  debug: false

			sonarr:
			  ip: 127.0.0.1
			  port: 8989
			  base_url: /sonarr
			  apikey: ''

			radarr:
			  ip: 127.0.0.1
			  port: 7878
			  base_url: /radarr
			  apikey: ''

			auth:
			  type: None
			  username: ''
			  password: ''
		EOSC
        echo_progress_done
    else
        echo_info "Existing config.yaml found, preserving user customizations"
    fi
    chown "${user}:${user}" "${config_dir}/config/config.yaml"

    # Create systemd service
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/${instance_name}.service" <<-SERV
		[Unit]
		Description=${app_pretty} ${name^} Instance
		After=syslog.target network.target

		[Service]
		User=${user}
		Group=${user}
		UMask=0002
		Type=simple
		WorkingDirectory=/opt/bazarr
		ExecStartPre=+/opt/swizzin-scripts/hooks/bazarr-apply-patches.sh
		ExecStart=${app_python} ${app_script} --config ${config_dir}
		Restart=on-failure
		RestartSec=5
		KillSignal=SIGINT
		TimeoutStopSec=20

		[Install]
		WantedBy=multi-user.target
	SERV
    systemctl daemon-reload
    echo_progress_done

    # Create nginx config if nginx is installed
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Installing nginx config"
        cat >"/etc/nginx/apps/${instance_name}.conf" <<-NGX
			location /${instance_name}/ {
			    proxy_pass http://127.0.0.1:${instance_port}/${instance_name}/;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header Host \$http_host;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection "Upgrade";
			    proxy_redirect off;
			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};

			    location /${instance_name}/api {
			        auth_basic off;
			        proxy_pass http://127.0.0.1:${instance_port}/${instance_name}/api;
			    }
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
            panel_register_app "${instance_name//-/_}" "${app_pretty} ${name^}" "/${instance_name}" "" "${instance_name}" "${app_name}" "" "false"
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

# Remove an instance
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
        _remove_nginx_conf "$instance_name"
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

# Interactive instance removal
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

# List all instances
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

# Patch base systemd unit with hardening fixes
_patch_base_service() {
    local service_file="/etc/systemd/system/${app_name}.service"
    [[ -f "$service_file" ]] || return 0

    local changed=false

    # Fix KillMode=process → control-group
    if grep -q 'KillMode=process' "$service_file" 2>/dev/null; then
        sed -i 's/KillMode=process/KillMode=control-group/' "$service_file"
        changed=true
    fi

    # Add KillMode if missing entirely
    if ! grep -q 'KillMode=' "$service_file" 2>/dev/null; then
        sed -i '/TimeoutStopSec=/a KillMode=control-group' "$service_file"
        changed=true
    fi

    if [[ "$changed" == "true" ]]; then
        systemctl daemon-reload
        echo_info "Patched base ${app_pretty} service (KillMode=control-group)"
    fi
}

# Install base app if not installed
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

    # Patch base service with hardening fixes
    _patch_base_service

    # Ensure base app has panel meta override
    _ensure_base_panel_meta

    # Deploy patched subtitle providers
    _deploy_provider_patches
}

# Pre-flight checks
_preflight() {
    if [[ ! -f /install/.nginx.lock ]]; then
        echo_error "nginx is not installed. Please install nginx first."
        exit 1
    fi
}

# Interactive add flow
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

# Migrate a single config from INI to YAML
_migrate_single_config() {
    local config_dir="$1"
    local service_name="$2"
    local ini_file="${config_dir}/config.ini"
    local yaml_file="${config_dir}/config.yaml"

    # Skip if already YAML or no INI exists
    if [[ -f "$yaml_file" ]]; then
        echo_info "Config already in YAML format: ${config_dir}"
        return 0
    fi

    if [[ ! -f "$ini_file" ]]; then
        echo_warn "No config found in: ${config_dir}"
        return 1
    fi

    echo_progress_start "Migrating ${service_name} config to YAML"

    # Parse INI values
    local ip port base_url
    ip=$(grep -oP '(?<=^ip = ).*' "$ini_file" 2>/dev/null || echo "127.0.0.1")
    port=$(grep -oP '(?<=^port = )\d+' "$ini_file" 2>/dev/null || echo "6767")
    base_url=$(grep -oP '(?<=^base_url = ).*' "$ini_file" 2>/dev/null || echo "/")

    # Stop service before migration
    if [[ -n "$service_name" ]] && systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
        systemctl stop "${service_name}.service"
    fi

    # Backup old INI
    mv "$ini_file" "${ini_file}.old"

    # Create new YAML config
    cat >"$yaml_file" <<-EOSC
		general:
		  ip: ${ip}
		  port: ${port}
		  base_url: ${base_url}
		  single_language: false
		  use_embedded_subs: true
		  debug: false

		sonarr:
		  ip: 127.0.0.1
		  port: 8989
		  base_url: /sonarr
		  apikey: ''

		radarr:
		  ip: 127.0.0.1
		  port: 7878
		  base_url: /radarr
		  apikey: ''

		auth:
		  type: None
		  username: ''
		  password: ''
	EOSC

    chown "${user}:${user}" "$yaml_file"

    # Restart service
    if [[ -n "$service_name" ]]; then
        systemctl start "${service_name}.service" 2>/dev/null || true
    fi

    echo_progress_done
    echo_info "Old config backed up to: ${ini_file}.old"
}

# Migrate base bazarr installation (INI to YAML)
_migrate_base() {
    local base_config_dir

    # Check new location first, then legacy location
    if [[ -d "/home/${user}/.config/${app_name}/config" ]]; then
        base_config_dir="/home/${user}/.config/${app_name}/config"
    elif [[ -d "/opt/bazarr/data/config" ]]; then
        base_config_dir="/opt/bazarr/data/config"
    else
        # No config dir found - skip silently (fresh install will create YAML)
        return 0
    fi

    _migrate_single_config "$base_config_dir" "$app_name"
}

# Migrate all instances
_migrate_instances() {
    local instances
    read -ra instances <<<"$(_get_instances)"

    if [[ ${#instances[@]} -eq 0 ]]; then
        echo_info "No additional instances to migrate"
        return 0
    fi

    for instance in "${instances[@]}"; do
        local config_dir="/home/${user}/.config/${app_name}-${instance}/config"
        _migrate_single_config "$config_dir" "${app_name}-${instance}"
    done
}

# Migrate all configs (base + instances)
# Handles: base location migration (/opt → ~/.config) + INI to YAML format
_migrate_all() {
    echo_info "Running ${app_pretty} migrations..."
    echo ""

    # Phase 1: Migrate base location if needed (protects from auto-update)
    if [[ -f "/install/.${app_lockname}.lock" ]]; then
        echo_info "Phase 1: Checking base ${app_pretty} data location..."
        _migrate_base_location
        echo ""
    fi

    # Phase 2: Migrate configs from INI to YAML format
    echo_info "Phase 2: Checking config format (INI → YAML)..."

    # Migrate base if installed
    if [[ -f "/install/.${app_lockname}.lock" ]]; then
        _migrate_base
    fi

    # Migrate instances
    _migrate_instances

    # Deploy patched subtitle providers
    _deploy_provider_patches

    echo ""
    echo_success "All migrations complete!"
}

# Migrate base bazarr data from /opt/bazarr/data/ to ~/.config/bazarr/
# This protects data from bazarr's destructive auto-update which wipes /opt/bazarr/
_migrate_base_location() {
    local old_data_dir="/opt/bazarr/data"
    local new_data_dir="/home/${user}/.config/${app_name}"
    local service_file="/etc/systemd/system/${app_name}.service"

    # Check if base bazarr is installed
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "Base ${app_pretty} is not installed"
        return 1
    fi

    # Check if already migrated (new location exists with config)
    if [[ -f "${new_data_dir}/config/config.yaml" ]]; then
        # Verify service uses new location
        if grep -q "\-\-config ${new_data_dir}" "$service_file" 2>/dev/null; then
            echo_info "Base ${app_pretty} already migrated to ${new_data_dir}"
            return 0
        fi
    fi

    # Check if old data exists
    if [[ ! -d "$old_data_dir" ]]; then
        # Maybe fresh install or data was already wiped by auto-update
        if [[ -d "$new_data_dir" ]]; then
            echo_info "Data already at new location: ${new_data_dir}"
        else
            echo_warn "No data found at ${old_data_dir} - may need fresh setup"
            mkdir -p "$new_data_dir"
            chown -R "${user}:${user}" "$new_data_dir"
        fi
    else
        echo_info "Migrating base ${app_pretty} data location"
        echo_info "From: ${old_data_dir}"
        echo_info "To:   ${new_data_dir}"
        echo ""

        # Stop service
        echo_progress_start "Stopping ${app_pretty}"
        systemctl stop "${app_name}.service" 2>/dev/null || true
        echo_progress_done

        # Move data to new location
        echo_progress_start "Moving data to new location"
        mkdir -p "$(dirname "$new_data_dir")"
        if [[ -d "$new_data_dir" ]]; then
            # Merge if new location already has some data
            cp -a "${old_data_dir}"/* "$new_data_dir"/ 2>/dev/null || true
            rm -rf "$old_data_dir"
        else
            mv "$old_data_dir" "$new_data_dir"
        fi
        chown -R "${user}:${user}" "$new_data_dir"
        echo_progress_done

        # Update backup folder path in config.yaml
        if [[ -f "${new_data_dir}/config/config.yaml" ]]; then
            echo_progress_start "Updating config paths"
            sed -i "s|folder: ${old_data_dir}/backup|folder: ${new_data_dir}/backup|" "${new_data_dir}/config/config.yaml"
            echo_progress_done
        fi
    fi

    # Update systemd service to use --config flag
    echo_progress_start "Updating systemd service"
    if ! grep -q "\-\-config" "$service_file" 2>/dev/null; then
        # Add --config flag to ExecStart
        sed -i "s|ExecStart=${app_python} ${app_script}|ExecStart=${app_python} ${app_script} --config ${new_data_dir}|" "$service_file"
    fi
    systemctl daemon-reload
    echo_progress_done

    # Start service
    echo_progress_start "Starting ${app_pretty}"
    systemctl start "${app_name}.service"
    echo_progress_done

    echo ""
    echo_success "Base ${app_pretty} migrated to ${new_data_dir}"
    echo_info "Data is now protected from auto-update overwrites"
}

# Main
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
            panel_register_app "${instance_name//-/_}" "${app_pretty} ${name^}" "/${instance_name}" "" "${instance_name}" "${app_name}" "" "false"
            echo_info "Registered: ${instance_name}"
        done
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for all ${app_pretty} instances"
        ;;
    "--migrate")
        _migrate_all
        ;;
    "--patch-providers")
        _deploy_provider_patches
        ;;
    "")
        _ensure_base_installed
        _add_interactive
        ;;
    *)
        echo "Usage: $0 [--add [name]|--remove [name] [--force]|--list|--register-panel|--migrate|--patch-providers]"
        echo ""
        echo "  (no args)              Install base if needed, then add instances"
        echo "  --add [name]           Add a new instance"
        echo "  --remove [name]        Remove instance(s)"
        echo "  --remove name --force  Remove instance without prompts"
        echo "  --list                 List all instances"
        echo "  --register-panel       Re-register all instances with panel"
        echo "  --migrate              Run all migrations:"
        echo "                           - Move base data to ~/.config/bazarr/"
        echo "                           - Convert INI configs to YAML format"
        echo "  --patch-providers      Re-apply Greek subtitle provider patches"
        exit 1
        ;;
esac
