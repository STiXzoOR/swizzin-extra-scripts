#!/bin/bash
set -euo pipefail
# nzbhydra2 installer
# STiXzoOR 2026
# Usage: bash nzbhydra2.sh [--update [--verbose]|--remove [--force]|--register-panel]
#
# NZBHydra2 — Newznab/Torznab meta-search that fronts multiple usenet indexers
# behind one endpoint. Used by Prowlarr/Sonarr/Radarr to query NZBgeek, NzbPlanet,
# NZBFinder, DrunkenSlug, etc. through a single Newznab interface.
# Upstream: github.com/theotherp/nzbhydra2  (image: linuxserver/nzbhydra2)

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
# Panel Helper - Download and cache for panel integration
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

app_name="nzbhydra2"
app_pretty="NZBHydra2"
app_lockname="${app_name}"
app_baseurl="${app_name}"

# linuxserver/nzbhydra2 follows the LSIO PUID/PGID/TZ pattern. Pin to a known
# tag rather than :latest for reproducible installs; bump on --update review.
app_image="lscr.io/linuxserver/nzbhydra2:latest"

# Runs in host network mode (matches repo convention for docker apps that may
# need to reach the host's arrs/downloaders for stats/sync features). Hydra
# binds directly to ${app_port} on the host; no docker port-mapping layer.

app_dir="/opt/${app_name}"
app_configdir="${app_dir}/config"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/nzbhydra.png"

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
_install_nzbhydra2() {
    mkdir -p "$app_configdir"
    chown -R "${user}:${user}" "$app_dir"

    local uid gid tz
    uid=$(id -u "$user")
    gid=$(id -g "$user")
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

    swizdb set "${app_name}/port" "$app_port"

    echo_progress_start "Generating Docker Compose configuration"

    # NZBHydra2 is a Spring Boot Java app — needs heap headroom. Default 1G is
    # plenty for typical 2-6 indexer setups; bump via DOCKER_MEM_LIMIT if you
    # add many indexers or run heavy search history.
    local cpu_limit="${DOCKER_CPU_LIMIT:-2}"
    local mem_limit="${DOCKER_MEM_LIMIT:-1G}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-256M}"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  ${app_name}:
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    network_mode: host
    environment:
      PUID: "${uid}"
      PGID: "${gid}"
      TZ: "${tz}"
    volumes:
      - ${app_configdir}:/config
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
        reservations:
          memory: ${mem_reserve}
    security_opt:
      - no-new-privileges:true
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

    _configure_urlbase_nzbhydra2
}

# ==============================================================================
# Config patches: urlBase, host bind, port
# ==============================================================================
# NZBHydra2 validates its yml on startup and rejects partial configs, so we
# can't pre-seed it. Pattern: wait for Hydra to write its own valid yml on
# first boot, patch three lines (urlBase, host, port), restart.
#
# - urlBase   → /${app_baseurl}   so the SPA + Newznab API live under subpath
# - host      → 127.0.0.1         so host-mode binding stays loopback-only
# - port      → ${app_port}       so Hydra binds on the swizdb-allocated port
#
# Idempotent: skips restart if all three lines already match the targets.
_configure_urlbase_nzbhydra2() {
    local yml="${app_configdir}/nzbhydra.yml"
    local target_urlbase="/${app_baseurl}"
    local target_host="127.0.0.1"
    local target_port="${app_port}"

    echo_progress_start "Waiting for NZBHydra2 to generate its config"
    local i
    for i in $(seq 1 30); do
        if [[ -f "$yml" ]] && grep -q "^  urlBase:" "$yml" 2>/dev/null; then
            break
        fi
        sleep 2
    done

    if [[ ! -f "$yml" ]]; then
        echo_error "NZBHydra2 didn't write its config within 60s — check 'docker logs ${app_name}'"
        exit 1
    fi
    echo_progress_done "Config generated"

    local cur_urlbase cur_host cur_port
    cur_urlbase=$(grep "^  urlBase:" "$yml" | head -1 | sed -E 's/^  urlBase: "?([^"]*)"?$/\1/')
    cur_host=$(grep "^  host:" "$yml" | head -1 | sed -E 's/^  host: "?([^"]*)"?$/\1/')
    cur_port=$(grep "^  port:" "$yml" | head -1 | sed -E 's/^  port: ([0-9]+)$/\1/')

    if [[ "$cur_urlbase" == "$target_urlbase" && "$cur_host" == "$target_host" && "$cur_port" == "$target_port" ]]; then
        echo_info "nzbhydra.yml already matches target (urlBase=$target_urlbase host=$target_host port=$target_port), no patch needed"
        return 0
    fi

    echo_progress_start "Patching nzbhydra.yml (urlBase=$target_urlbase, host=$target_host, port=$target_port)"
    local escaped_urlbase
    escaped_urlbase=$(_sed_escape_value "$target_urlbase" 2>/dev/null || printf '%s' "$target_urlbase")
    sed -i -E "s|^(  urlBase: ).*$|\1\"${escaped_urlbase}\"|" "$yml"
    sed -i -E "s|^(  host: ).*$|\1\"${target_host}\"|" "$yml"
    sed -i -E "s|^(  port: ).*$|\1${target_port}|" "$yml"
    docker compose -f "${app_dir}/docker-compose.yml" restart >>"$log" 2>&1 || {
        echo_error "Failed to restart container after yml patch"
        exit 1
    }

    # Wait for Hydra to reach 200 at the new base path on the new port
    for i in $(seq 1 30); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
            "http://127.0.0.1:${app_port}/${app_baseurl}/" 2>/dev/null || echo "000")
        if [[ "$code" == "200" || "$code" == "302" ]]; then
            echo_progress_done "NZBHydra2 active at http://127.0.0.1:${app_port}/${app_baseurl}/"
            return 0
        fi
        sleep 3
    done
    echo_error "NZBHydra2 didn't come up at /${app_baseurl}/ after yml patch"
    exit 1
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_nzbhydra2() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=NZBHydra2 (usenet meta-indexer)
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

MemoryMax=1G
CPUQuota=200%
TasksMax=1024

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
# NZBHydra2 supports urlBase natively (set in nzbhydra.yml at install time), so
# plain proxy_pass works — no sub_filter rewrites needed.
#
# The /api subpath skips auth_basic so Prowlarr can hit it via API key without
# tripping basic auth. Mirrors how the *arr scripts expose their /api routes.
_nginx_nzbhydra2() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port};
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

			location ^~ /${app_baseurl}/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port};
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
# Update
# ==============================================================================
_update_nzbhydra2() {
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

    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_nzbhydra2() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
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
        systemctl reload nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_configdir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Usage
# ==============================================================================
_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  (no args)             Install"
    echo "  --update [--verbose]  Pull latest Docker image"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
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
    "--update")
        _update_nzbhydra2
        ;;
    "--remove")
        _remove_nzbhydra2 "${2:-}"
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
        exit 0
        ;;
    "")
        ;;
    *)
        _usage
        ;;
esac

if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    _cleanup_needed=true

    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _install_nzbhydra2
    _systemd_nzbhydra2
    _nginx_nzbhydra2

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
    echo ""
    echo_info "Next steps:"
    echo_info "  1. Open the UI, set the admin auth (Settings > Authentication)"
    echo_info "  2. Add your indexers (Settings > Indexers): NZBgeek, NzbPlanet, etc."
    echo_info "  3. Copy NZBHydra2's API key (Settings > Main > API key)"
    echo_info "  4. In Prowlarr, add a new Newznab indexer pointing at"
    echo_info "       http://127.0.0.1:${app_port}/${app_baseurl}/"
    echo_info "     with the API key from step 3. Then disable the direct"
    echo_info "     NZBgeek / NzbPlanet indexers in Prowlarr."
fi
