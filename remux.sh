#!/bin/bash
set -euo pipefail
# remux installer
# STiXzoOR 2026
# Usage: bash remux.sh [--latest] [--update [--latest] [--verbose]|--remove [--force]|--register-panel]
#
# Subdomain-only — Remux exposes a Jellyfin-compatible API and has no base-path
# support, so clients (Infuse, Swiftfin, Jellyfin apps) need a clean root URL.
# Set REMUX_DOMAIN env var to skip the interactive domain prompt.
#
# Remux — self-hosted media server with a Jellyfin-compatible API. Aggregates
# content from Stremio addons, local files, WebDAV servers, and torrents, with
# built-in streaming, playback tracking, and user management. Ships with
# jellyfin-ffmpeg for transcoding. Docker-based, single-container.
#
# Upstream: https://github.com/lostb1t/remux
# Image:    ghcr.io/lostb1t/remux  (:latest stable | :nightly via --latest)
#
# Media access: /mnt is mounted read-only (rslave) into the container so
# /mnt/symlinks and its FUSE-backed targets (zurg/nzbdav rclone mounts)
# resolve. WebDAV sources (zurg, nzbdav) can be added via the admin dashboard.

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
        if [[ -n "$_nginx_config_written" ]]; then
            rm -f "$_nginx_config_written"
            # If we wrote a subdomain vhost, also nuke the symlink
            rm -f "/etc/nginx/sites-enabled/$(basename "$_nginx_config_written")"
        fi
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
app_name="remux"
app_pretty="Remux"
app_lockname="${app_name}"
app_icon_name="${app_name}"
# No selfhst icon for remux (checked 2026-08) — use the upstream repo logo
app_icon_url="https://raw.githubusercontent.com/lostb1t/remux/main/logo.png"

app_image_repo="ghcr.io/lostb1t/remux"
# app_image + app_channel are resolved by _resolve_image (after flag parsing),
# honouring --latest / REMUX_USE_LATEST_TAG and the persisted swizdb channel.
app_image=""
app_channel=""
app_container_port="3000"

app_dir="/opt/remux"
app_datadir="${app_dir}/data"
app_servicefile="${app_name}.service"

# ==============================================================================
# Release Channel / Image Tag Resolution
# ==============================================================================
# Mirrors aiostreams.sh's --latest: opt into the bleeding-edge build (:nightly)
# instead of the stable :latest tag. Resolution precedence:
#   --latest / REMUX_USE_LATEST_TAG  >  persisted swizdb channel  >  stable
_resolve_image() {
    local use_latest="${REMUX_USE_LATEST_TAG:-}"
    use_latest="${use_latest,,}"
    if [[ "$use_latest" == "true" || "$use_latest" == "1" || "$use_latest" == "yes" ]]; then
        app_channel="nightly"
    else
        local stored
        stored="$(swizdb get "${app_name}/channel" 2>/dev/null)" || true
        app_channel="${stored:-stable}"
    fi
    if [[ "$app_channel" == "nightly" ]]; then
        app_image="${app_image_repo}:nightly"
    else
        app_channel="stable"
        app_image="${app_image_repo}:latest"
    fi
}

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# ==============================================================================
# Port Allocation
# ==============================================================================
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

# ==============================================================================
# Domain Resolution (subdomain only — Jellyfin-compatible clients need a clean
# root URL and Remux has no base-path support)
# ==============================================================================
backup_dir="/opt/swizzin-extras/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "${app_name}/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${REMUX_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${REMUX_DOMAIN:-}" ]; then
        echo_info "Using domain from REMUX_DOMAIN: $REMUX_DOMAIN"
        app_domain="$REMUX_DOMAIN"
        swizdb set "${app_name}/domain" "$app_domain"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for ${app_pretty}" "[$existing_domain]"
    else
        echo_query "Enter domain for ${app_pretty}" "(e.g., remux.example.com)"
    fi
    read -r input_domain </dev/tty || true

    if [ -z "${input_domain:-}" ]; then
        if [ -n "$existing_domain" ]; then
            app_domain="$existing_domain"
        else
            echo_error "Domain is required"
            exit 1
        fi
    else
        if [[ ! "$input_domain" =~ \. ]]; then
            echo_error "Invalid domain format (must contain at least one dot)"
            exit 1
        fi
        if [[ "$input_domain" =~ [[:space:]] ]]; then
            echo_error "Domain cannot contain spaces"
            exit 1
        fi
        app_domain="$input_domain"
    fi

    echo_info "Using domain: $app_domain"
    swizdb set "${app_name}/domain" "$app_domain"
    export REMUX_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${REMUX_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from REMUX_LE_INTERACTIVE: $REMUX_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export REMUX_LE_INTERACTIVE="yes"
    else
        export REMUX_LE_INTERACTIVE="no"
    fi
}

_request_certificate() {
    local domain="$1"
    local le_hostname="${REMUX_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${REMUX_LE_INTERACTIVE:-no}"

    if [ -d "$cert_dir" ]; then
        echo_info "Let's Encrypt certificate already exists for $le_hostname"
        return 0
    fi

    echo_info "Requesting Let's Encrypt certificate for $le_hostname"

    local result
    if [ "$le_interactive" = "yes" ]; then
        echo_info "Running Let's Encrypt in interactive mode..."
        LE_HOSTNAME="$le_hostname" box install letsencrypt </dev/tty
        result=$?
    else
        LE_HOSTNAME="$le_hostname" LE_DEFAULTCONF=no LE_BOOL_CF=no \
            box install letsencrypt >>"$log" 2>&1
        result=$?
    fi

    if [ $result -ne 0 ]; then
        echo_error "Failed to obtain Let's Encrypt certificate for $le_hostname"
        echo_error "Check $log for details or run manually: LE_HOSTNAME=$le_hostname box install letsencrypt"
        echo_error "Note: the domain must resolve to this server before http-01 validation can succeed"
        exit 1
    fi

    echo_info "Let's Encrypt certificate issued for $le_hostname"
}

# ==============================================================================
# Organizr Integration (matches template-subdomain.sh)
# ==============================================================================

_get_organizr_domain() {
    if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
        grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
    fi
}

_exclude_from_organizr() {
    local modified=false
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"

    if [ -f "$organizr_config" ] && grep -q "^${app_name}:" "$organizr_config"; then
        echo_progress_start "Removing ${app_pretty} from Organizr protected apps"
        sed -i "/^${app_name}:/d" "$organizr_config"
        modified=true
    fi

    if [ -f "$apps_include" ] && grep -q "include /etc/nginx/apps/${app_name}.conf;" "$apps_include"; then
        sed -i "\|include /etc/nginx/apps/${app_name}.conf;|d" "$apps_include"
        modified=true
    fi

    if [ "$modified" = true ]; then
        echo_progress_done "Removed from Organizr"
    fi
}

_include_in_organizr() {
    if [ -f "$organizr_config" ] && ! grep -q "^${app_name}:" "$organizr_config"; then
        echo_info "Note: ${app_pretty} can be re-added to Organizr protection via: bash organizr.sh --configure"
    fi
}

# ==============================================================================
# Backup Helpers (matches template-subdomain.sh)
# ==============================================================================

_ensure_backup_dir() {
    [ -d "$backup_dir" ] || mkdir -p "$backup_dir"
}

_backup_file() {
    local src="$1"
    local name
    name=$(basename "$src")
    _ensure_backup_dir
    [ -f "$src" ] && cp "$src" "$backup_dir/${name}.bak"
}

# ==============================================================================
# State Detection (matches template-subdomain.sh)
# ==============================================================================
# Remux has no subfolder mode (Jellyfin clients need a clean root URL), so the
# state machine collapses to: not_installed | subdomain | unknown.
# (`unknown` means lock exists but vhost doesn't — typically a partial install,
# e.g. cert issuance failed or DNS wasn't pointed at first install attempt.)
# ==============================================================================

_get_install_state() {
    if [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo "not_installed"
    elif [ -f "$subdomain_vhost" ]; then
        echo "subdomain"
    elif [ -f "$subfolder_conf" ]; then
        echo "subfolder" # never shipped for remux; treat as 'unknown'
    else
        echo "unknown"
    fi
}

# ==============================================================================
# Panel Registration
# ==============================================================================

_register_panel() {
    local domain="$1"
    _load_panel_helper
    if ! command -v panel_register_app >/dev/null 2>&1; then
        echo_info "Panel helper not available — skipping panel registration"
        return 0
    fi
    panel_register_app \
        "$app_name" \
        "$app_pretty" \
        "" \
        "https://${domain}" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
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
_install_remux() {
    mkdir -p "$app_datadir"
    chown -R "${user}:${user}" "$app_dir"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    swizdb set "${app_name}/port" "$app_port"
    swizdb set "${app_name}/channel" "$app_channel"

    echo_progress_start "Generating Docker Compose configuration"

    # Resource limits (override via env vars). Remux bundles jellyfin-ffmpeg
    # and may transcode, so give it the same headroom as other media apps.
    local cpu_limit="${DOCKER_CPU_LIMIT:-4}"
    local mem_limit="${DOCKER_MEM_LIMIT:-4G}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-512M}"

    # HOME=/data: the image defaults to running as root; when dropped to
    # ${uid}:${gid} the bundled torrent engine (rqbit) aborts on startup
    # trying to create $HOME/.cache. Everything else already writes to /data
    # (DATABASE_URL, LOG_FILE, TORRENT_DATA_DIR are baked into the image).
    #
    # /mnt is read-only + rslave so /mnt/symlinks and the FUSE-backed rclone
    # mounts it points into (zurg, nzbdav) resolve inside the container and
    # follow host remounts.
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  remux:
    image: ${app_image}
    container_name: remux
    restart: unless-stopped
    user: "${uid}:${gid}"
    environment:
      - HOME=/data
    ports:
      - "127.0.0.1:${app_port}:${app_container_port}"
    volumes:
      - ${app_datadir}:/data
      - /mnt:/mnt:ro,rslave
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
        reservations:
          memory: ${mem_reserve}
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:${app_container_port}/health"]
      interval: 1m
      timeout: 10s
      retries: 3
      start_period: 30s
COMPOSE

    chmod 644 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

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
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_remux() {
    echo_progress_start "Installing systemd service"

    local mem_max="${SYSTEMD_MEM_MAX:-4G}"
    local cpu_quota="${SYSTEMD_CPU_QUOTA:-400%}"
    local tasks_max="${SYSTEMD_TASKS_MAX:-4096}"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Jellyfin-compatible media server)
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

# Resource limits
MemoryMax=${mem_max}
CPUQuota=${cpu_quota}
TasksMax=${tasks_max}
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Subdomain Vhost Creation (matches emby.sh / aiostreams.sh)
# ==============================================================================

_create_subdomain_vhost() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local organizr_domain
    organizr_domain=$(_get_organizr_domain)

    echo_progress_start "Creating subdomain nginx vhost"

    # Clean up any stray subfolder config (never shipped for remux, but heal)
    if [ -f "$subfolder_conf" ]; then
        _backup_file "$subfolder_conf"
        rm -f "$subfolder_conf"
    fi

    # Shared map for WebSocket + keepalive compatibility (also written by
    # emby.sh — guard so we don't clobber)
    if [[ ! -f /etc/nginx/conf.d/map-connection-upgrade.conf ]]; then
        cat >/etc/nginx/conf.d/map-connection-upgrade.conf <<'MAPCONF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}
MAPCONF
    fi

    local csp_header=""
    if [ -n "$organizr_domain" ]; then
        csp_header="add_header Content-Security-Policy \"frame-ancestors 'self' https://$organizr_domain\";"
    fi

    cat >"$subdomain_vhost" <<VHOST
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location /.well-known {
        alias /srv/.well-known;
        allow all;
        default_type "text/plain";
        autoindex on;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $domain;

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    include snippets/ssl-params.conf;

    client_max_body_size 0;
    proxy_redirect off;
    proxy_buffering off;

    # Streaming timeouts (1 hour for long-running streams)
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    ${csp_header}

    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;

        # WebSocket support (Jellyfin-compatible /socket endpoint)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Range requests for seeking in direct streams
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }
}
VHOST

    [ -L "$subdomain_enabled" ] || ln -s "$subdomain_vhost" "$subdomain_enabled"

    _nginx_config_written="$subdomain_vhost"

    echo_progress_done "Subdomain vhost created"
}

# ==============================================================================
# Subdomain Install Entry Point (matches aiostreams.sh _install_subdomain)
# ==============================================================================
# State machine:
#   not_installed → docker install → container up → systemd → cert → vhost → panel
#   unknown       → cert → vhost → panel (heals partial installs)
#   subdomain     → no-op (already configured)
# ==============================================================================

_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${REMUX_LE_HOSTNAME:-$domain}"
    local state
    state=$(_get_install_state)

    echo_info "${app_pretty} Subdomain Setup"
    echo_info "Domain: $domain"
    [ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
    echo_info "Current state: $state"

    case "$state" in
        "not_installed")
            echo_info "Setting ${app_pretty} owner = ${user}"
            swizdb set "${app_name}/owner" "$user"
            _install_docker
            _install_remux
            _systemd_remux
            ;& # fallthrough to subdomain setup
        "subfolder" | "unknown")
            _request_certificate "$domain"
            if [ -f "/install/.nginx.lock" ]; then
                _create_subdomain_vhost "$domain" "$le_hostname"
                _reload_nginx
                _register_panel "$domain"
                _exclude_from_organizr
            else
                echo_info "nginx not installed — skipping vhost and panel registration"
            fi

            # Create lock file (idempotent — same flow as fresh install)
            touch "/install/.${app_lockname}.lock"
            _lock_file_created="/install/.${app_lockname}.lock"
            _cleanup_needed=false

            _post_install_info
            echo_success "${app_pretty} ready at https://$domain"
            ;;
        "subdomain")
            echo_info "${app_pretty} is already configured in subdomain mode"
            echo_info "Access at: https://$domain"
            ;;
        *)
            echo_error "Unknown install state: $state"
            exit 1
            ;;
    esac
}

# ==============================================================================
# Post-Install Info
# ==============================================================================
_post_install_info() {
    echo ""
    echo_info "${app_pretty} installed successfully"
    echo ""
    echo_info "Web UI:    https://${app_domain}/"
    echo_info "Dashboard: https://${app_domain}/dashboard"
    echo_info "Local:     http://127.0.0.1:${app_port}/"
    echo_info "Channel:   ${app_channel} (${app_image})"
    echo ""
    echo_info "First run: open the web UI and create the admin account, then add"
    echo_info "sources via the admin dashboard:"
    echo_info "  • Local files:  /mnt/symlinks/... (mounted read-only)"
    echo_info "  • WebDAV:       point at zurg/nzbdav WebDAV endpoints"
    echo_info "  • Stremio addons and torrents as desired"
    echo ""
    echo_info "Jellyfin-compatible clients (Infuse, Swiftfin, ...) connect to:"
    echo_info "  https://${app_domain}"
    echo ""
    echo_info "Logs:    docker logs -f remux"
    echo_info "Data:    ${app_datadir}"
    echo ""
}

# ==============================================================================
# Update
# ==============================================================================
_update_remux() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}... (channel: ${app_channel})"

    # Sync release channel + image tag (honours --latest / persisted channel)
    swizdb set "${app_name}/channel" "$app_channel" 2>/dev/null || true
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        local _cur_img
        _cur_img=$(grep -E "^[[:space:]]*image:" "${app_dir}/docker-compose.yml" | head -1 | sed -E 's/^[[:space:]]*image:[[:space:]]*//')
        if [[ -n "$app_image" && "$_cur_img" != "$app_image" ]]; then
            echo_info "Switching image: ${_cur_img:-?} -> ${app_image}"
            sed -i -E "s|^([[:space:]]*image:[[:space:]]*).*|\\1${app_image}|" "${app_dir}/docker-compose.yml"
        fi
    fi

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
_remove_remux() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration and data?" N; then
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

    if [[ -L "$subdomain_enabled" ]] || [[ -f "$subdomain_vhost" ]]; then
        echo_progress_start "Removing subdomain vhost"
        rm -f "$subdomain_enabled" "$subdomain_vhost"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Subdomain vhost removed"
    fi
    if [[ -f "$subfolder_conf" ]]; then
        echo_progress_start "Removing stray subpath nginx app config"
        if command -v _remove_nginx_conf >/dev/null 2>&1; then
            _remove_nginx_conf "$app_name"
        else
            rm -f "$subfolder_conf"
        fi
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Stray subpath nginx app config removed"
    fi

    _include_in_organizr

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
        swizdb clear "${app_name}/domain" 2>/dev/null || true
        swizdb clear "${app_name}/channel" 2>/dev/null || true
    else
        echo_info "Data kept at: ${app_datadir}"
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
    echo "  (no args)               Interactive setup (stable channel)"
    echo "  --latest                Use the nightly channel (:nightly)"
    echo "  --update [--latest]     Pull image and recreate (add --latest to switch to nightly)"
    echo "  --remove [--force]      Complete removal (prompts to purge config)"
    echo "  --register-panel        Re-register with swizzin panel"
    echo ""
    echo "Environment variable overrides:"
    echo "  REMUX_DOMAIN            Subdomain for Remux (e.g. remux.example.com)"
    echo "  REMUX_LE_INTERACTIVE    yes|no — interactive Let's Encrypt mode (default: no)"
    echo "  REMUX_LE_HOSTNAME       Request cert for a different hostname (e.g. wildcard)"
    echo "  REMUX_USE_LATEST_TAG    true — same as --latest (nightly channel)"
    echo "  DOCKER_CPU_LIMIT        Compose CPU limit (default: 4)"
    echo "  DOCKER_MEM_LIMIT        Compose memory limit (default: 4G)"
    echo "  DOCKER_MEM_RESERVE      Compose memory reservation (default: 512M)"
    echo "  SYSTEMD_MEM_MAX         Systemd MemoryMax (default: 4G)"
    echo "  SYSTEMD_CPU_QUOTA       Systemd CPUQuota (default: 400%)"
    exit 1
}

# ==============================================================================
# Main
# ==============================================================================

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
        --latest) REMUX_USE_LATEST_TAG="true" ;;
    esac
done

# Resolve release channel + Docker image tag (honours --latest / persisted channel)
_resolve_image

# Rebuild positional args without global flags so the command dispatch below sees
# only the primary command (--update/--remove/...) or nothing (interactive install).
_args=()
for arg in "$@"; do
    case "$arg" in
        --latest | --verbose) ;; # consumed above
        *) _args+=("$arg") ;;
    esac
done
if [[ ${#_args[@]} -gt 0 ]]; then set -- "${_args[@]}"; else set --; fi

case "${1:-}" in
    "--update")
        _update_remux
        ;;
    "--remove")
        _remove_remux "${2:-}"
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        app_domain="$(_get_domain)"
        if [[ -z "$app_domain" ]]; then
            echo_error "No domain stored in swizdb for ${app_name}. Run the installer first or set REMUX_DOMAIN."
            exit 1
        fi
        _register_panel "$app_domain"
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_pretty}"
        exit 0
        ;;
    "")
        # Interactive install (fall through to install logic below)
        ;;
    *)
        _usage
        ;;
esac

# ==============================================================================
# Install Logic
# ==============================================================================
# All paths funnel through _install_subdomain (matches emby.sh/aiostreams.sh).
# The state machine inside handles fresh installs, partial-install healing
# (lock exists but no vhost — e.g. DNS wasn't pointed on first run), and
# already-configured no-ops.
# ==============================================================================
_cleanup_needed=true
_install_subdomain
# _install_subdomain sets _cleanup_needed=false on success
