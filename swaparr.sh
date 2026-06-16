#!/bin/bash
# swaparr installer
# STiXzoOR 2026
# Usage: bash swaparr.sh [--update [--verbose]|--remove [--force]|--register-panel]

set -euo pipefail

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

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
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
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

app_name="swaparr"
app_pretty="Swaparr"
app_lockname="${app_name}"

# Docker image
app_image="ghcr.io/thijmengthn/swaparr:latest"

# Directories
app_dir="/opt/${app_name}"

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/swaparr.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
# Get owner from swizdb or fall back to master user
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"

# ==============================================================================
# Starr Instance Auto-Discovery
# ==============================================================================
# Parallel arrays populated by _discover_arr_instances
ARR_NAMES=()
ARR_TYPES=()    # "sonarr", "radarr", "lidarr", "readarr", "whisparr"
ARR_PORTS=()
ARR_APIKEYS=()
ARR_URLBASES=()

_discover_arr_instances() {
    echo_progress_start "Discovering Starr instances"

    local lock_basename arr_type config_dir_name instance_name
    local cfg port apikey urlbase

    for lock in /install/.sonarr.lock /install/.sonarr_*.lock \
        /install/.radarr.lock /install/.radarr_*.lock \
        /install/.lidarr.lock /install/.lidarr_*.lock \
        /install/.readarr.lock /install/.readarr_*.lock \
        /install/.whisparr.lock /install/.whisparr_*.lock; do
        [[ -f "$lock" ]] || continue

        lock_basename=$(basename "$lock" .lock)
        lock_basename="${lock_basename#.}" # Remove leading dot

        # Determine arr type and config directory name
        case "$lock_basename" in
            sonarr)
                arr_type="sonarr"
                config_dir_name="Sonarr"
                instance_name="sonarr"
                ;;
            sonarr_*)
                arr_type="sonarr"
                instance_name="${lock_basename/sonarr_/sonarr-}"
                config_dir_name="${instance_name}"
                ;;
            radarr)
                arr_type="radarr"
                config_dir_name="Radarr"
                instance_name="radarr"
                ;;
            radarr_*)
                arr_type="radarr"
                instance_name="${lock_basename/radarr_/radarr-}"
                config_dir_name="${instance_name}"
                ;;
            lidarr)
                arr_type="lidarr"
                config_dir_name="Lidarr"
                instance_name="lidarr"
                ;;
            lidarr_*)
                arr_type="lidarr"
                instance_name="${lock_basename/lidarr_/lidarr-}"
                config_dir_name="${instance_name}"
                ;;
            readarr)
                arr_type="readarr"
                config_dir_name="Readarr"
                instance_name="readarr"
                ;;
            readarr_*)
                arr_type="readarr"
                instance_name="${lock_basename/readarr_/readarr-}"
                config_dir_name="${instance_name}"
                ;;
            whisparr)
                arr_type="whisparr"
                config_dir_name="Whisparr"
                instance_name="whisparr"
                ;;
            whisparr_*)
                arr_type="whisparr"
                instance_name="${lock_basename/whisparr_/whisparr-}"
                config_dir_name="${instance_name}"
                ;;
            *) continue ;;
        esac

        # Find config.xml
        for cfg in /home/*/.config/"${config_dir_name}"/config.xml; do
            [[ -f "$cfg" ]] || continue

            port=$(grep -oP '(?<=<Port>)[^<]+' "$cfg" 2>/dev/null) || continue
            apikey=$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" 2>/dev/null) || continue
            urlbase=$(grep -oP '(?<=<UrlBase>)[^<]+' "$cfg" 2>/dev/null) || true

            ARR_NAMES+=("$instance_name")
            ARR_TYPES+=("$arr_type")
            ARR_PORTS+=("$port")
            ARR_APIKEYS+=("$apikey")
            ARR_URLBASES+=("${urlbase:-}")

            _verbose "Found ${instance_name} on port ${port} (urlbase: ${urlbase:-none})"
            break
        done
    done

    if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
        echo_warn "No Starr instances found — Swaparr requires at least one (Sonarr, Radarr, Lidarr, Readarr, or Whisparr)"
        echo_progress_done "Discovery complete"
        return 1
    else
        echo_progress_done "Found ${#ARR_NAMES[@]} Starr instance(s): ${ARR_NAMES[*]}"
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
_install_swaparr() {
    mkdir -p "$app_dir"

    echo_progress_start "Generating Docker Compose configuration"

    # Swaparr defaults (overridable via environment variables)
    local max_strikes="${SWAPARR_MAX_STRIKES:-3}"
    local scan_interval="${SWAPARR_SCAN_INTERVAL:-10m}"
    local max_download_time="${SWAPARR_MAX_DOWNLOAD_TIME:-2h}"
    local ignore_above_size="${SWAPARR_IGNORE_ABOVE_SIZE:-25 GB}"
    local remove_from_client="${SWAPARR_REMOVE_FROM_CLIENT:-true}"
    local strike_queued="${SWAPARR_STRIKE_QUEUED:-false}"

    # Resource limits (overridable via environment variables)
    local cpu_limit="${DOCKER_CPU_LIMIT:-1}"
    local mem_limit="${DOCKER_MEM_LIMIT:-256M}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-64M}"

    # Build docker-compose.yml with one container per Starr instance
    {
        echo "services:"

        local i
        for i in "${!ARR_NAMES[@]}"; do
            local name="${ARR_NAMES[$i]}"
            local arr_type="${ARR_TYPES[$i]}"
            local port="${ARR_PORTS[$i]}"
            local apikey="${ARR_APIKEYS[$i]}"
            local urlbase="${ARR_URLBASES[$i]}"

            # Build the base URL — include urlbase if set
            local baseurl="http://127.0.0.1:${port}"
            if [[ -n "$urlbase" ]]; then
                baseurl="${baseurl}/${urlbase#/}"
            fi

            cat <<COMPOSE

  swaparr-${name}:
    image: ${app_image}
    container_name: swaparr-${name}
    restart: unless-stopped
    network_mode: host
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
        reservations:
          memory: ${mem_reserve}
    environment:
      - BASEURL=${baseurl}
      - APIKEY=${apikey}
      - PLATFORM=${arr_type}
      - MAX_STRIKES=${max_strikes}
      - SCAN_INTERVAL=${scan_interval}
      - MAX_DOWNLOAD_TIME=${max_download_time}
      - IGNORE_ABOVE_SIZE=${ignore_above_size}
      - REMOVE_FROM_CLIENT=${remove_from_client}
      - STRIKE_QUEUED=${strike_queued}
COMPOSE
        done
    } >"${app_dir}/docker-compose.yml"

    chmod 600 "${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling ${app_pretty} Docker image"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting ${app_pretty} containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "${app_pretty} containers started"
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_swaparr() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Stop and remove containers
    echo_progress_start "Stopping ${app_pretty} containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

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

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Purge config
    echo_progress_start "Removing configuration"
    rm -rf "$app_dir"
    echo_progress_done "All files purged"
    swizdb clear "${app_name}/owner" 2>/dev/null || true

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Update (Docker-specific: pull latest image and recreate containers)
# ==============================================================================
_update_swaparr() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    # Re-discover Starr instances to pick up new apps or changed API keys
    _discover_arr_instances || {
        echo_error "No Starr instances found — nothing to configure"
        exit 1
    }

    # Regenerate docker-compose.yml with current Starr discovery
    _install_swaparr

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_swaparr() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} - Stalled download manager for Starr apps
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

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
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
    _remove_swaparr "${2:-}"
fi

# Handle --update flag
if [[ "${1:-}" == "--update" ]]; then
    _update_swaparr
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
            "" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "false"
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
    _cleanup_needed=true

    # Discover Starr instances
    _discover_arr_instances || {
        echo_error "Cannot install ${app_pretty} without at least one Starr instance"
        exit 1
    }

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    # Run installation
    _install_docker
    _install_swaparr
    _systemd_swaparr

    _cleanup_needed=false
fi

# Register with panel (runs on both fresh install and re-run)
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "$app_pretty" \
        "" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "false"
fi

# Create lock file
touch "/install/.${app_lockname}.lock"

echo_success "${app_pretty} installed — monitoring ${#ARR_NAMES[@]} Starr instance(s)"
