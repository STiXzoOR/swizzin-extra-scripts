#!/bin/bash
set -euo pipefail
# tracearr installer
# Usage: bash tracearr.sh [--update [--verbose]|--remove [--force]|--register-panel]

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

app_name="tracearr"
app_pretty="Tracearr"
app_lockname="${app_name}"
app_baseurl="${app_name}"

app_dir="/opt/tracearr"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/tracearr.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# ==============================================================================
# Port Allocation (3 dynamic ports: app, postgres, redis)
# ==============================================================================
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

if _existing_pg_port="$(swizdb get "${app_name}/pg_port" 2>/dev/null)" && [[ -n "$_existing_pg_port" ]]; then
    pg_port="$_existing_pg_port"
else
    pg_port=$(port 10000 12000)
fi

if _existing_redis_port="$(swizdb get "${app_name}/redis_port" 2>/dev/null)" && [[ -n "$_existing_redis_port" ]]; then
    redis_port="$_existing_redis_port"
else
    redis_port=$(port 10000 12000)
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
# App Installation (3-container compose: app, timescaledb, redis)
# ==============================================================================
_install_tracearr() {
    mkdir -p "${app_dir}/pgdata" "${app_dir}/redis" "${app_dir}/backups"
    # TimescaleDB HA image runs as postgres (UID 1000)
    chown 1000:1000 "${app_dir}/pgdata"

    # Generate credentials (persist all in swizdb so updates reuse them)
    local db_pass jwt_secret cookie_secret
    if db_pass="$(swizdb get "${app_name}/db_pass" 2>/dev/null)" && [[ -n "$db_pass" ]]; then
        _verbose "Reusing existing DB password from swizdb"
    else
        db_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c -32)
        swizdb set "${app_name}/db_pass" "$db_pass"
    fi

    # Persist JWT_SECRET and COOKIE_SECRET in swizdb so they survive updates
    if jwt_secret="$(swizdb get "${app_name}/jwt_secret" 2>/dev/null)" && [[ -n "$jwt_secret" ]]; then
        _verbose "Reusing existing JWT_SECRET from swizdb"
    else
        jwt_secret=$(openssl rand -hex 32)
        swizdb set "${app_name}/jwt_secret" "$jwt_secret"
    fi

    if cookie_secret="$(swizdb get "${app_name}/cookie_secret" 2>/dev/null)" && [[ -n "$cookie_secret" ]]; then
        _verbose "Reusing existing COOKIE_SECRET from swizdb"
    else
        cookie_secret=$(openssl rand -hex 32)
        swizdb set "${app_name}/cookie_secret" "$cookie_secret"
    fi

    # Persist ports in swizdb
    swizdb set "${app_name}/port" "$app_port"
    swizdb set "${app_name}/pg_port" "$pg_port"
    swizdb set "${app_name}/redis_port" "$redis_port"

    echo_progress_start "Generating Docker Compose configuration"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  tracearr:
    image: ghcr.io/connorgallopo/tracearr:latest
    container_name: tracearr
    restart: unless-stopped
    network_mode: host
    environment:
      PORT: "${app_port}"
      BASE_PATH: "/tracearr"
      TRUST_PROXY: "true"
      JWT_SECRET: "${jwt_secret}"
      COOKIE_SECRET: "${cookie_secret}"
      DATABASE_URL: "postgres://tracearr:${db_pass}@127.0.0.1:${pg_port}/tracearr"
      REDIS_URL: "redis://127.0.0.1:${redis_port}"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://127.0.0.1:${app_port}/health || exit 1"]
      interval: 30s
      timeout: 10s
      start_period: 30s
      retries: 3
    depends_on:
      tracearr-postgres:
        condition: service_healthy
      tracearr-redis:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  tracearr-postgres:
    image: timescale/timescaledb-ha:pg18.1-ts2.25.0
    container_name: tracearr-postgres
    restart: unless-stopped
    shm_size: 512m
    network_mode: host
    environment:
      POSTGRES_USER: tracearr
      POSTGRES_PASSWORD: "${db_pass}"
      POSTGRES_DB: tracearr
    command:
      - postgres
      - -c
      - max_locks_per_transaction=4096
      - -c
      - timescaledb.telemetry_level=off
      - -c
      - port=${pg_port}
    volumes:
      - ${app_dir}/pgdata:/home/postgres/pgdata/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tracearr -p ${pg_port}"]
      interval: 10s
      timeout: 5s
      retries: 5
    security_opt:
      - no-new-privileges:true

  tracearr-redis:
    image: redis:8-alpine
    container_name: tracearr-redis
    restart: unless-stopped
    network_mode: host
    command: redis-server --appendonly yes --port ${redis_port}
    volumes:
      - ${app_dir}/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "${redis_port}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    security_opt:
      - no-new-privileges:true
COMPOSE

    # Secure compose file (contains credentials)
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling Tracearr Docker images (this may take a while)"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker images"
        exit 1
    }
    echo_progress_done "Docker images pulled"

    echo_progress_start "Starting Tracearr containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "Tracearr containers started"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_tracearr() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=Tracearr
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

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_tracearr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /tracearr {
			    return 301 /tracearr/;
			}

			location ^~ /tracearr/ {
			    proxy_pass http://127.0.0.1:${app_port}/tracearr/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;
			    proxy_read_timeout 3600s;
			    proxy_send_timeout 3600s;

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
# Health Check
# ==============================================================================
_healthcheck_tracearr() {
    echo_progress_start "Waiting for Tracearr to become healthy"
    local retries=30
    local i=0
    while (( i < retries )); do
        if curl -sf "http://127.0.0.1:${app_port}/health" | grep -q '"ok"' 2>/dev/null; then
            echo_progress_done "Tracearr is healthy"
            return 0
        fi
        sleep 2
        (( i++ )) || true
    done
    echo_warn "Tracearr health check timed out - the app may still be starting"
}

# ==============================================================================
# Update
# ==============================================================================
_update_tracearr() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Pulling latest ${app_pretty} images"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest images"
        exit 1
    }
    echo_progress_done "Latest images pulled"

    echo_progress_start "Recreating ${app_pretty} containers"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_tracearr() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration (skip prompt if --force)
    local purgeconfig
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove all containers
    echo_progress_start "Stopping ${app_pretty} containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

    # Remove all Docker images
    echo_progress_start "Removing Docker images"
    docker rmi ghcr.io/connorgallopo/tracearr:latest >>"$log" 2>&1 || true
    docker rmi timescale/timescaledb-ha:pg18.1-ts2.25.0 >>"$log" 2>&1 || true
    docker rmi redis:8-alpine >>"$log" 2>&1 || true
    echo_progress_done "Docker images removed"

    # Remove Docker network
    docker network rm tracearr-net 2>/dev/null || true

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
        swizdb clear "${app_name}/pg_port" 2>/dev/null || true
        swizdb clear "${app_name}/redis_port" 2>/dev/null || true
        swizdb clear "${app_name}/jwt_secret" 2>/dev/null || true
        swizdb clear "${app_name}/cookie_secret" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_dir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    # Remove lock file
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
    echo "  (no args)             Install Tracearr"
    echo "  --update [--verbose]  Pull latest Docker images"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
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
        _update_tracearr
        ;;
    "--remove")
        _remove_tracearr "${2:-}"
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
        # Install (fall through to install logic below)
        ;;
    *)
        _usage
        ;;
esac

# ==============================================================================
# Install Logic
# ==============================================================================
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    _cleanup_needed=true

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    # Run installation
    _install_docker
    _install_tracearr
    _systemd_tracearr
    _nginx_tracearr
    _healthcheck_tracearr

    # Register with panel
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
    _lock_file_created="/install/.${app_lockname}.lock"
    _cleanup_needed=false

    echo_success "${app_pretty} installed"
    echo_info "Port: ${app_port}"
    echo_info "Connect your Emby server through the web UI after first login"
fi
