#!/bin/bash
set -euo pipefail
# stremthru installer
# STiXzoOR 2026
# Usage: bash stremthru.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

# shellcheck source=lib/debrid-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/debrid-utils.sh"

# shellcheck source=lib/prowlarr-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/prowlarr-utils.sh" 2>/dev/null || true

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

app_name="stremthru"
app_pretty="StremThru"
app_lockname="${app_name}"
app_baseurl="${app_name}"
app_image="muniftanjim/stremthru:latest"

app_dir="/opt/${app_name}"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://emojiapi.dev/api/v1/sparkles/256.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================

if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Port persistence - read existing port from swizdb, allocate only on fresh install
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

# ==============================================================================
# Docker Installation
# ==============================================================================
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_progress_start "Installing Docker"

    apt_install ca-certificates curl gnupg

    # Source os-release once for distro detection
    . /etc/os-release

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$log" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update >>"$log" 2>&1

    # Use apt-get directly instead of apt_install — Docker's post-install
    # triggers service restarts that Swizzin's apt_install treats as errors
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }

    systemctl enable --now docker >>"$log" 2>&1

    # Verify Docker is running
    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_progress_done "Docker installed"
}

# ==============================================================================
# App Installation
# ==============================================================================
_install_stremthru() {
    mkdir -p "${app_dir}/data"
    chown -R "${user}:${user}" "$app_dir"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    # Persist port in swizdb
    swizdb set "${app_name}/port" "$app_port"

    # Prompt for debrid credentials (shared library)
    # Returns 0 = new config, sets debrid_provider + debrid_key
    # Returns 1 = existing config, skip credential generation
    local need_credentials=true
    if ! _prompt_debrid_provider "STREMTHRU" "${app_dir}/docker-compose.yml" "STREMTHRU_STORE_AUTH"; then
        need_credentials=false
    fi

    if [[ "$need_credentials" == "true" ]]; then
        # Prompt for dashboard password or generate one
        local auth_password=""
        echo_query "Enter a dashboard password (leave empty to auto-generate):" ""
        read -rs auth_password </dev/tty
        echo "" # newline after silent read

        if [[ -z "$auth_password" ]]; then
            auth_password=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c -16)
            echo_info "Generated password: ${auth_password}"
        fi

        echo_progress_start "Generating Docker Compose configuration"

        # Write secrets to env file (not in compose)
        cat >"${app_dir}/.env" <<ENV
STREMTHRU_AUTH=${user}:${auth_password}
STREMTHRU_STORE_AUTH=${user}:${debrid_provider}:${debrid_key}
ENV
        chmod 600 "${app_dir}/.env"
        chown root:root "${app_dir}/.env"

        cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  stremthru:
    image: ${app_image}
    container_name: stremthru
    restart: unless-stopped
    network_mode: host
    user: "${uid}:${gid}"
    env_file: .env
    environment:
      STREMTHRU_PORT: "${app_port}"
    volumes:
      - ${app_dir}/data:/app/data
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
COMPOSE

        chmod 600 "${app_dir}/docker-compose.yml"
        chown root:root "${app_dir}/docker-compose.yml"

        echo_progress_done "Docker Compose configuration generated"

        # Store auth password for Prowlarr config (used later)
        _stremthru_auth_password="$auth_password"
    else
        echo_info "Using existing Docker Compose configuration"
        _stremthru_auth_password=""
    fi

    echo_progress_start "Pulling ${app_pretty} Docker image"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "${app_pretty} container started"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_stremthru() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Debrid Proxy/Companion with Torznab)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_stremthru() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect / /${app_baseurl}/;
			    proxy_cookie_path / /${app_baseurl}/;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Rewrite SPA's hardcoded /dash paths to include subfolder prefix
			    # (TanStack Router routes, API calls, asset references)
			    proxy_set_header Accept-Encoding "";
			    sub_filter_once off;
			    sub_filter_types application/javascript text/javascript;
			    sub_filter '/dash/' '/${app_baseurl}/dash/';
			    sub_filter '"/dash"' '"/${app_baseurl}/dash"';
			    sub_filter "'/dash'" "'/${app_baseurl}/dash'";

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /${app_baseurl}/v0/torznab {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/v0/torznab;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

        _nginx_config_written="/etc/nginx/apps/${app_name}.conf"
        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} will run on port ${app_port}"
    fi
}

# ==============================================================================
# Prowlarr Auto-Configuration
# ==============================================================================
_configure_prowlarr() {
    local torznab_url="http://127.0.0.1:${app_port}/v0/torznab"
    local api_key="${_stremthru_auth_password:-}"

    # Attempt auto-configuration if Prowlarr is installed and we have credentials
    if [[ -n "$api_key" ]] && command -v _discover_prowlarr >/dev/null 2>&1 && _discover_prowlarr; then
        _add_prowlarr_torznab "StremThru" "$torznab_url" "$api_key" || true
    fi

    # Always display manual instructions
    if command -v _display_prowlarr_torznab_info >/dev/null 2>&1; then
        _display_prowlarr_torznab_info "StremThru" "$torznab_url" \
            "API Key: Use the generated auth password from STREMTHRU_AUTH"
    fi
}

# ==============================================================================
# Fresh Install
# ==============================================================================
_install_fresh() {
    if [[ -f "/install/.${app_lockname}.lock" ]]; then
        echo_info "${app_pretty} already installed"
        return
    fi

    _cleanup_needed=true

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _install_stremthru
    _systemd_stremthru
    _nginx_stremthru
    _configure_prowlarr

    # Panel registration
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

    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
    _cleanup_needed=false
    echo_success "${app_pretty} installed"
    echo_info "Access at: https://your-server/${app_baseurl}/"
}

# ==============================================================================
# Update
# ==============================================================================
_update_stremthru() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Pulling latest ${app_pretty} image"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating ${app_pretty} container"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_stremthru() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration (skip prompt if --force)
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove container
    echo_progress_start "Stopping ${app_pretty} container"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi "$app_image" >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
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

    # Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_dir}"
    fi

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
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

case "${1:-}" in
    "--update")
        _update_stremthru
        ;;
    "--remove")
        _remove_stremthru "${2:-}"
        ;;
    "--register-panel")
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
        ;;
    "")
        _install_fresh
        ;;
    *)
        echo "Usage: $0 [--update [--verbose]|--remove [--force]|--register-panel]"
        exit 1
        ;;
esac
