#!/bin/bash
set -euo pipefail
# babysitarr installer
# STiXzoOR 2026
# Usage: bash babysitarr.sh [--update [--verbose]|--remove [--force]|--register-panel]
#
# Babysitarr (https://github.com/DAdjadj/Babysitarr) is a Python daemon that
# watches your *arr stack + Decypharr/Real-Debrid and auto-heals common failure
# modes (stuck downloads, looping torrents, dead queue entries, missing library
# files, etc.). It exposes a web dashboard at port 8284.
#
# IMPORTANT — Swizzin caveats:
#   * Swizzin installs Sonarr/Radarr/Prowlarr as native systemd services, NOT
#     Docker containers. Babysitarr's "restart the arr" auto-heal path uses
#     `docker restart <name>` and will silently no-op against native installs.
#     Pure-API checks (queue cleanup, blocklist, library missing-file scan,
#     indexer reset) still work fine.
#   * Decypharr is also a native systemd service here. Babysitarr's "stuck
#     download → restart Decypharr" recovery is similarly a no-op. Your existing
#     decypharr-watchdog.sh handles that path.
#   * Babysitarr builds from source (no published image as of 2026-05). This
#     installer clones the repo and runs `docker compose build` locally.

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
# Cleanup Trap
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
app_name="babysitarr"
app_pretty="Babysitarr"
app_lockname="${app_name//-/}"
app_baseurl="${app_name}"

app_repo="https://github.com/DAdjadj/Babysitarr.git"
app_container_port="8284"

app_dir="/opt/${app_name}"
app_srcdir="${app_dir}/src"
app_datadir="${app_dir}/data"

app_servicefile="${app_name}.service"
app_image="babysitarr:local"

app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/babysitarr.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    # Babysitarr defaults to 8284; honor that when free, else allocate.
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${app_container_port}\$"; then
        app_port="$app_container_port"
    else
        app_port=$(port 10000 12000)
    fi
fi

# ==============================================================================
# Arr Discovery
# ==============================================================================
# Walk Swizzin's lock files + ~/.config/<App>/config.xml to build the
# pipe-separated arr env vars Babysitarr expects: name|type|host|port|apikey
#
# Multi-instance naming convention here:
#   /install/.sonarr.lock        -> ~/.config/Sonarr        -> name=sonarr
#   /install/.sonarr_4k.lock     -> ~/.config/sonarr-4k     -> name=sonarr-4k
#   /install/.sonarr_anime.lock  -> ~/.config/sonarr-anime  -> name=sonarr-anime
#   (Prowlarr is detected but not exported — Babysitarr only consumes
#    Sonarr/Radarr for queue/import checks. Its config dir is still mounted so
#    the indexer-reset feature can reach Prowlarr's DB.)
declare -A _arr_envs=()
declare -A _arr_configdirs=()

_discover_arr() {
    local lock="$1"
    local app_type="$2" # sonarr|radarr|prowlarr
    local cfgdir_native cfgname arr_name

    [[ -f "$lock" ]] || return 0

    local lock_basename
    lock_basename="$(basename "$lock")"
    lock_basename="${lock_basename#.}"
    lock_basename="${lock_basename%.lock}"

    case "$lock_basename" in
        "$app_type") # base install
            cfgname="${app_type^}" # Sonarr / Radarr / Prowlarr
            arr_name="$app_type"
            ;;
        "${app_type}_"*)
            local suffix="${lock_basename#"${app_type}"_}"
            cfgname="${app_type}-${suffix}" # sonarr-4k, radarr-4k, sonarr-anime
            arr_name="${app_type}-${suffix}"
            ;;
        *)
            return 0
            ;;
    esac

    cfgdir_native="/home/${user}/.config/${cfgname}"
    if [[ ! -f "${cfgdir_native}/config.xml" ]]; then
        _verbose "Skipping ${arr_name}: ${cfgdir_native}/config.xml missing"
        return 0
    fi

    local arr_port arr_apikey
    arr_port="$(sed -n 's:.*<Port>\(.*\)</Port>.*:\1:p' "${cfgdir_native}/config.xml" | head -n1)"
    arr_apikey="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "${cfgdir_native}/config.xml" | head -n1)"

    if [[ -z "$arr_port" || -z "$arr_apikey" ]]; then
        echo_warn "Discovered ${arr_name} but could not parse Port/ApiKey from config.xml — skipping"
        return 0
    fi

    _arr_configdirs["$arr_name"]="$cfgdir_native"
    if [[ "$app_type" != "prowlarr" ]]; then
        _arr_envs["$arr_name"]="${arr_name}|${app_type}|host.docker.internal|${arr_port}|${arr_apikey}"
    fi
}

_discover_arrs() {
    local lock
    for lock in /install/.sonarr.lock /install/.sonarr_*.lock; do
        [[ -e "$lock" ]] || continue
        _discover_arr "$lock" sonarr
    done
    for lock in /install/.radarr.lock /install/.radarr_*.lock; do
        [[ -e "$lock" ]] || continue
        _discover_arr "$lock" radarr
    done
    if [[ -e /install/.prowlarr.lock ]]; then
        _discover_arr /install/.prowlarr.lock prowlarr
    fi
}

# ==============================================================================
# Docker Installation
# ==============================================================================
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_progress_start "Installing Docker"
    apt_install ca-certificates curl gnupg git

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
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }
    systemctl enable --now docker >>"$log" 2>&1
    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi
    echo_progress_done "Docker installed"
}

# ==============================================================================
# App Installation
# ==============================================================================
_clone_or_update_source() {
    if [[ -d "${app_srcdir}/.git" ]]; then
        echo_progress_start "Updating Babysitarr source"
        git -C "$app_srcdir" fetch --quiet origin >>"$log" 2>&1
        git -C "$app_srcdir" reset --quiet --hard origin/HEAD >>"$log" 2>&1
        echo_progress_done "Source updated"
    else
        echo_progress_start "Cloning Babysitarr source"
        rm -rf "$app_srcdir"
        git clone --depth 1 "$app_repo" "$app_srcdir" >>"$log" 2>&1 || {
            echo_error "Failed to clone ${app_repo}"
            exit 1
        }
        echo_progress_done "Source cloned"
    fi
}

_write_env_file() {
    # Secrets-only file. .env in the compose dir is auto-loaded by `docker compose`.
    # Pre-fill what swizdb can give us; everything else stays blank for the user.
    local envfile="${app_dir}/.env"
    if [[ -f "$envfile" ]]; then
        echo_info "Preserving existing ${envfile}"
        chmod 600 "$envfile"
        return
    fi

    {
        echo "# Babysitarr secrets — fill in and run \`systemctl restart ${app_servicefile}\`"
        echo "# Web dashboard auth is enforced by nginx (htpasswd), not by these vars."
        echo
        echo "RD_API_KEY="
        echo
        echo "# Email (optional)"
        echo "SMTP_HOST=smtp.gmail.com"
        echo "SMTP_PORT=587"
        echo "SMTP_USER="
        echo "SMTP_PASS="
        echo "EMAIL_FROM="
        echo "EMAIL_TO="
        echo
        echo "# Discord webhook (optional)"
        echo "DISCORD_WEBHOOK_URL="
        echo
        echo "# Download dirs Babysitarr should watch, comma-separated, container paths."
        echo "# Default mount is /downloads (read-only) — see compose volumes."
        echo "DOWNLOAD_DIRS=/downloads"
    } >"$envfile"
    chown "${user}:${user}" "$envfile"
    chmod 600 "$envfile"
}

_write_compose_file() {
    local compose="${app_dir}/docker-compose.yml"

    # Decypharr state file (Swizzin native install).
    local decypharr_cfg="/home/${user}/.config/Decypharr"
    local decypharr_volume=""
    local decypharr_state_env=""
    if [[ -f "${decypharr_cfg}/torrents.json" ]]; then
        decypharr_volume="      - ${decypharr_cfg}:/decypharr-config:ro"
        decypharr_state_env="      - DECYPHARR_STATE=/decypharr-config/torrents.json"
    fi

    # Arr config-dir mounts (read-only) — used by the indexer-reset feature
    # which pokes sqlite databases directly.
    local arr_volumes=""
    local arr_envs=""
    local arr_name
    for arr_name in "${!_arr_configdirs[@]}"; do
        arr_volumes+="      - ${_arr_configdirs[$arr_name]}:/arr-configs/${arr_name}:ro"$'\n'
    done
    local env_var
    for arr_name in "${!_arr_envs[@]}"; do
        env_var="$(echo "$arr_name" | tr '[:lower:]-' '[:upper:]_')"
        arr_envs+="      - ${env_var}=${_arr_envs[$arr_name]}"$'\n'
    done

    {
        cat <<COMPOSE
services:
  ${app_name}:
    build: ./src
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    env_file:
      - .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "127.0.0.1:${app_port}:${app_container_port}"
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          memory: 128M
    environment:
      - TZ=\${TZ:-UTC}
      - CHECK_INTERVAL=120
      - STUCK_DOWNLOAD_TIMEOUT=600
      - LOOP_THRESHOLD=5
      - IMPORT_STALL_TIMEOUT=300
      - STUCK_QUEUE_TIMEOUT=1800
      - MAX_WORKERS=3
      - WEB_PORT=${app_container_port}
      - EMAIL_COOLDOWN=3600
      - DECYPHARR_URL=http://host.docker.internal:8282
COMPOSE
        [[ -n "$decypharr_state_env" ]] && echo "$decypharr_state_env"
        [[ -n "$arr_envs" ]] && printf '%s' "$arr_envs"
        echo "    volumes:"
        echo "      - /var/run/docker.sock:/var/run/docker.sock"
        echo "      - ${app_datadir}:/data"
        [[ -n "$decypharr_volume" ]] && echo "$decypharr_volume"
        [[ -n "$arr_volumes" ]] && printf '%s' "$arr_volumes"
        echo "      # Add bind mounts for your download dirs here, then set"
        echo "      # DOWNLOAD_DIRS in .env to the container-side paths."
        echo "      # - /mnt/zurg/__all__:/downloads:ro"
    } >"$compose"

    chown -R "${user}:${user}" "$compose"
}

_install_babysitarr() {
    mkdir -p "$app_dir" "$app_datadir"
    chown -R "${user}:${user}" "$app_dir"

    swizdb set "${app_name}/port" "$app_port"

    _discover_arrs
    if [[ ${#_arr_envs[@]} -eq 0 ]]; then
        echo_warn "No Sonarr/Radarr instances discovered — Babysitarr will start with no arrs configured."
        echo_warn "Add them by editing ${app_dir}/docker-compose.yml after install."
    else
        echo_info "Discovered arrs: ${!_arr_envs[*]}"
    fi

    _clone_or_update_source
    _write_env_file
    _write_compose_file

    echo_progress_start "Building Babysitarr image"
    docker compose -f "${app_dir}/docker-compose.yml" build >>"$log" 2>&1 || {
        echo_error "Failed to build Docker image"
        exit 1
    }
    echo_progress_done "Image built"

    echo_progress_start "Starting ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "${app_pretty} container started"
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_babysitarr() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig="false"
    if ask "Would you like to purge the configuration and state?" N; then
        purgeconfig="true"
    fi

    echo_progress_start "Stopping ${app_pretty} container"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    echo_progress_start "Removing Docker image"
    docker rmi "$app_image" >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/${app_name}.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    if [[ "$purgeconfig" == "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_dir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    rm -f "/install/.${app_lockname}.lock"
    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Update
# ==============================================================================
_update_babysitarr() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    _clone_or_update_source

    echo_progress_start "Rebuilding Babysitarr image"
    _verbose "Running: docker compose build"
    docker compose -f "${app_dir}/docker-compose.yml" build >>"$log" 2>&1 || {
        echo_error "Failed to rebuild image"
        exit 1
    }
    echo_progress_done "Image rebuilt"

    echo_progress_start "Recreating ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d --force-recreate >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Systemd Service
# ==============================================================================
_systemd_babysitarr() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty}
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=180
TimeoutStopSec=30

MemoryMax=1G
TasksMax=2048
LimitNOFILE=65536

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
_nginx_babysitarr() {
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
			    proxy_redirect off;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;
			    proxy_read_timeout 90s;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
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
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

case "${1:-}" in
    --remove)
        _remove_babysitarr "${2:-}"
        ;;
    --update)
        _update_babysitarr
        ;;
    --register-panel)
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
        ;;
esac

if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    _cleanup_needed=true
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _install_babysitarr
    _systemd_babysitarr
    _nginx_babysitarr
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
fi

touch "/install/.${app_lockname}.lock"
_lock_file_created="/install/.${app_lockname}.lock"
_cleanup_needed=false

echo_success "${app_pretty} installed"
echo_info "Access at: https://your-server/${app_baseurl}/"
echo_info "Fill in secrets: ${app_dir}/.env  →  systemctl restart ${app_servicefile}"
echo_info "Verify discovered arrs / add DOWNLOAD_DIRS mounts: ${app_dir}/docker-compose.yml"
