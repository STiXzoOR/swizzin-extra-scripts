#!/bin/bash
set -euo pipefail
# posterizarr installer
# STiXzoOR 2026
# Usage: bash posterizarr.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

# ==============================================================================
# Panel Helper
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
    if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
        . "${SCRIPT_DIR}/panel_helpers.sh"
        return
    fi
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
app_name="posterizarr"
app_pretty="Posterizarr"
app_lockname="${app_name}"
app_baseurl="${app_name}"

# Docker image
app_image="ghcr.io/fscorrupt/posterizarr:latest"
app_container_port="8000"

# Directories
app_dir="/opt/${app_name}"
app_configdir="${app_dir}/config"
app_assetsdir="${app_dir}/assets"
app_assetsbackupdir="${app_dir}/assetsbackup"
app_manualassetsdir="${app_dir}/manualassets"

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/posterizarr.png"

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
# Config Generation
# ==============================================================================
_detect_emby() {
    local emby_port="8096"
    local emby_token=""

    [[ -f /install/.emby.lock ]] || return 1

    # Check for stored token from a previous install
    emby_token=$(swizdb get "${app_name}/emby_token" 2>/dev/null) || true

    if [[ -z "$emby_token" ]]; then
        _verbose "Creating Emby API key for ${app_pretty}"

        local admin_token=""
        local emby_auth_db="/var/lib/emby/data/authentication.db"
        if [[ -f "$emby_auth_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
            admin_token=$(sqlite3 "$emby_auth_db" \
                "SELECT AccessToken FROM Tokens_2 WHERE IsActive=1 ORDER BY DateLastActivityInt DESC LIMIT 1;" 2>/dev/null) || true
        fi

        if [[ -n "$admin_token" ]]; then
            curl -s -X POST \
                "http://127.0.0.1:${emby_port}/emby/Auth/Keys" \
                -H "X-Emby-Token: ${admin_token}" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "App=${app_pretty}" 2>/dev/null || true

            local keys_json
            keys_json=$(curl -s -H "X-Emby-Token: ${admin_token}" \
                "http://127.0.0.1:${emby_port}/emby/Auth/Keys" 2>/dev/null) || true
            if [[ -n "$keys_json" ]]; then
                emby_token=$(echo "$keys_json" | jq -r \
                    ".Items[]? | select(.AppName == \"${app_pretty}\") | .AccessToken" 2>/dev/null | head -1) || true
            fi
        fi

        if [[ -z "$emby_token" ]]; then
            echo_warn "Could not auto-create Emby API key."
            echo_info "Create one manually: Emby Dashboard > API Keys > New"
            echo_query "Enter Emby API key (or leave empty to skip):" ""
            read -r emby_token </dev/tty 2>/dev/null || true
        fi
    fi

    if [[ -n "$emby_token" ]]; then
        swizdb set "${app_name}/emby_token" "$emby_token"
        EMBY_URL="http://127.0.0.1:${emby_port}/emby"
        EMBY_TOKEN="$emby_token"
        return 0
    fi
    return 1
}

_generate_config() {
    if [[ -f "${app_configdir}/config.json" ]]; then
        echo_info "Existing config found at ${app_configdir}/config.json, not overwriting"
        return 0
    fi

    echo_progress_start "Generating default configuration"

    # Download official example config (app's config checker is strict about structure)
    if ! curl -sf "https://raw.githubusercontent.com/fscorrupt/Posterizarr/main/config.example.json" \
            -o "${app_configdir}/config.json" 2>/dev/null; then
        echo_error "Failed to download example config"
        return 1
    fi

    # Auto-detect Emby and inject settings
    EMBY_URL=""
    EMBY_TOKEN=""
    if _detect_emby; then
        python3 -c "
import json, sys
with open('${app_configdir}/config.json') as f:
    d = json.load(f)
d['EmbyPart']['UseEmby'] = 'true'
d['EmbyPart']['EmbyUrl'] = '${EMBY_URL}'
d['ApiPart']['EmbyAPIKey'] = '${EMBY_TOKEN}'
d['PlexPart']['UsePlex'] = 'false'
with open('${app_configdir}/config.json', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
        echo_info "Emby detected — API key configured automatically"
    fi

    chmod 600 "${app_configdir}/config.json"
    echo_progress_done "Default configuration generated"
}

# ==============================================================================
# App Installation
# ==============================================================================
_install_posterizarr() {
    mkdir -p "${app_configdir}" "${app_assetsdir}" "${app_assetsbackupdir}" "${app_manualassetsdir}"
    chown -R "${user}:${user}" "${app_dir}"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    # Persist port in swizdb
    swizdb set "${app_name}/port" "$app_port"

    # Get system timezone
    local system_tz="UTC"
    if [[ -f /etc/timezone ]]; then
        system_tz=$(cat /etc/timezone)
    elif [[ -L /etc/localtime ]]; then
        system_tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
    fi

    # Generate default config if not present
    _generate_config

    echo_progress_start "Generating Docker Compose configuration"

    local cpu_limit="${DOCKER_CPU_LIMIT:-4}"
    local mem_limit="${DOCKER_MEM_LIMIT:-4G}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-512M}"

    # Use host networking to avoid UFW/Docker firewall conflicts
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  ${app_name}:
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    user: "${uid}:${gid}"
    network_mode: host
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
        reservations:
          memory: ${mem_reserve}
    environment:
      - TZ=${system_tz}
      - TERM=xterm
      - RUN_TIME=disabled
      - APP_PORT=${app_port}
    volumes:
      - ${app_configdir}:/config
      - ${app_assetsdir}:/assets
      - ${app_assetsbackupdir}:/assetsbackup
      - ${app_manualassetsdir}:/manualassets
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:${app_port}/api"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
COMPOSE

    echo_progress_done "Docker Compose configuration generated"

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

    # Fix ownership after container startup (container may create files as root)
    chown -R "${user}:${user}" "${app_dir}"
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_posterizarr() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration
    if ask "Would you like to purge the configuration and assets?" N; then
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
    if [[ "$purgeconfig" == "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_configdir}"
        echo_info "Assets kept at: ${app_assetsdir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Update (Docker-specific: pull latest image and recreate container)
# ==============================================================================
_update_posterizarr() {
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
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_posterizarr() {
    echo_progress_start "Installing systemd service"

    local mem_max="${SYSTEMD_MEM_MAX:-4G}"
    local cpu_quota="${SYSTEMD_CPU_QUOTA:-400%}"
    local tasks_max="${SYSTEMD_TASKS_MAX:-4096}"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Poster Artwork Manager)
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
TimeoutStopSec=30

# Resource limits to prevent runaway processes
MemoryMax=${mem_max}
CPUQuota=${cpu_quota}
TasksMax=${tasks_max}
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_detect_router_pattern() {
    # Auto-detect the minified BrowserRouter JSX call pattern from the current build.
    # Returns the sub_filter match string, e.g. "e.jsx(Tr,{children"
    local index_js
    index_js=$(curl -sf "http://127.0.0.1:${app_port}/" | grep -oP '/assets/index-[^"]+\.js' | head -1) || return 1
    [[ -z "$index_js" ]] && return 1

    local js_content
    js_content=$(curl -sf "http://127.0.0.1:${app_port}${index_js}") || return 1

    # Find the App root component (rendered inside StrictMode)
    local app_var
    app_var=$(echo "$js_content" | grep -oP 'StrictMode,\{children:e\.jsx\(\K\w+' | head -1)
    [[ -z "$app_var" ]] && return 1

    # The App component's first child in its return chain is BrowserRouter
    local router_var
    router_var=$(echo "$js_content" | grep -oP "function ${app_var}\(\)\{return e\.jsx\(\K\w+" | head -1)
    [[ -z "$router_var" ]] && return 1

    echo "e.jsx(${router_var},{children"
}

_nginx_posterizarr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        # Auto-detect BrowserRouter JSX pattern for basename injection
        local router_pattern=""
        local basename_filter=""
        router_pattern=$(_detect_router_pattern) || true
        if [[ -n "$router_pattern" ]]; then
            basename_filter="sub_filter '${router_pattern}' '${router_pattern%%,*},basename:\"/${app_baseurl}\",children';"
            _verbose "Detected BrowserRouter pattern: ${router_pattern}"
        else
            echo_warn "Could not detect BrowserRouter pattern — client-side routing may not work under subfolder"
        fi

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			    proxy_pass http://127.0.0.1:${app_port}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect off;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Rewrite paths in all response types
			    proxy_set_header Accept-Encoding "";
			    sub_filter_once off;
			    sub_filter_types text/css text/javascript application/javascript application/json;

			    # Inject React Router basename (auto-detected, regenerated on --update)
			    ${basename_filter}

			    # API base URL constants (multiple per chunk, stable pattern across builds)
			    sub_filter '="/api"' '="/${app_baseurl}/api"';

			    # HTML attributes
			    sub_filter 'href="/' 'href="/${app_baseurl}/';
			    sub_filter 'src="/' 'src="/${app_baseurl}/';

			    # JS fetch/string literals and backtick template literals
			    sub_filter '"/api/' '"/${app_baseurl}/api/';
			    sub_filter '\`/api/' '\`/${app_baseurl}/api/';

			    # Static image/asset references
			    sub_filter '"/images/' '"/${app_baseurl}/images/';
			    sub_filter '"/logo.png' '"/${app_baseurl}/logo.png';
			    sub_filter '"/favicon' '"/${app_baseurl}/favicon';
			    sub_filter '\`/poster_assets/' '\`/${app_baseurl}/poster_assets/';

			    # CSS url()
			    sub_filter 'url(/' 'url(/${app_baseurl}/';
			}

			# Webhook endpoints - no auth required (arr services call these)
			location ^~ /${app_baseurl}/api/webhook/ {
			    auth_basic off;
			    proxy_pass http://127.0.0.1:${app_port}/api/webhook/;
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
# Main
# ==============================================================================

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

# Handle --remove flag
if [[ "${1:-}" == "--remove" ]]; then
    _remove_posterizarr "${2:-}"
fi

# Handle --update flag
if [[ "${1:-}" == "--update" ]]; then
    _update_posterizarr
fi

# Handle --register-panel flag
if [[ "${1:-}" == "--register-panel" ]]; then
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
    echo_info "${app_pretty} is already installed"
else
    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _cleanup_needed=true

    # Run installation
    _install_docker
    _install_posterizarr
    _systemd_posterizarr
    _nginx_posterizarr

    _cleanup_needed=false
fi

# Register with panel (runs on both fresh install and re-run)
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
echo_info "Port: ${app_port}"
echo_info "Configure poster sources (TMDB, Fanart.tv, TVDB API keys) via the Web UI"
echo_info "Arr webhook path: /${app_baseurl}/api/webhook/arr"
