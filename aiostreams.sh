#!/bin/bash
set -euo pipefail
# aiostreams installer
# STiXzoOR 2026
# Usage: bash aiostreams.sh [--latest] [--update [--latest] [--verbose]|--remove [--force]|--register-panel]
#
# Subdomain-only — Next.js root-absolute asset paths make subpath unreliable.
# Set AIOSTREAMS_DOMAIN env var to skip the interactive domain prompt.
#
# AIOStreams — Stremio super-addon that consolidates multiple debrid services
# and Stremio addons into a single, highly customisable addon with filtering,
# sorting, and formatting. Docker-based, single-container.
#
# Upstream: https://github.com/Viren070/AIOStreams
# Image:    ghcr.io/viren070/aiostreams  (:latest stable | :nightly via --latest)
#
# Release channel: stable (:latest, <=2.29.x, ADDON_PASSWORD) is the default.
# --latest selects the rolling :nightly tag (v2.30+ preview) which replaces
# ADDON_PASSWORD with AIOSTREAMS_AUTH session login on the configure page.

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
app_name="aiostreams"
app_pretty="AIOStreams"
app_lockname="${app_name}"
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/aiostreams.png"

app_image_repo="ghcr.io/viren070/aiostreams"
# app_image + app_channel are resolved by _resolve_image (after flag parsing),
# honouring --latest / AIOSTREAMS_USE_LATEST_TAG and the persisted swizdb channel.
app_image=""
app_channel=""
app_container_port="3000"

app_dir="/opt/aiostreams"
app_datadir="${app_dir}/data"
app_servicefile="${app_name}.service"

# ==============================================================================
# Release Channel / Image Tag Resolution
# ==============================================================================
# Mirrors zurg.sh's --latest: opt into the bleeding-edge build. For this Docker
# app that is the rolling :nightly tag (v2.30+ preview with AIOSTREAMS_AUTH
# session login) instead of the stable :latest tag. Resolution precedence:
#   --latest / AIOSTREAMS_USE_LATEST_TAG  >  persisted swizdb channel  >  stable
_resolve_image() {
    local use_latest="${AIOSTREAMS_USE_LATEST_TAG:-}"
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

# Build an AIOSTREAMS_AUTH "user:password" value (nightly login). Honours
# AIOSTREAMS_AUTH_USER / AIOSTREAMS_AUTH_PASSWORD, else owner + random password.
_gen_aiostreams_auth() {
    local u="${AIOSTREAMS_AUTH_USER:-$user}"
    local p="${AIOSTREAMS_AUTH_PASSWORD:-}"
    [[ -z "$p" ]] && p="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c -24)"
    printf '%s:%s' "$u" "$p"
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
# Domain Resolution (subdomain only — AIOStreams is a Next.js SPA with root-
# absolute asset paths; subpath via sub_filter is too fragile to recommend)
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
    echo "${AIOSTREAMS_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${AIOSTREAMS_DOMAIN:-}" ]; then
        echo_info "Using domain from AIOSTREAMS_DOMAIN: $AIOSTREAMS_DOMAIN"
        app_domain="$AIOSTREAMS_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for ${app_pretty}" "[$existing_domain]"
    else
        echo_query "Enter domain for ${app_pretty}" "(e.g., aiostreams.example.com)"
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
    export AIOSTREAMS_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${AIOSTREAMS_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from AIOSTREAMS_LE_INTERACTIVE: $AIOSTREAMS_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export AIOSTREAMS_LE_INTERACTIVE="yes"
    else
        export AIOSTREAMS_LE_INTERACTIVE="no"
    fi
}

_request_certificate() {
    local domain="$1"
    local le_hostname="${AIOSTREAMS_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${AIOSTREAMS_LE_INTERACTIVE:-no}"

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
# AIOStreams has no subfolder mode (Next.js root-absolute asset paths), so the
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
        echo "subfolder"   # legacy from pre-refactor installs; treat as 'unknown'
    else
        echo "unknown"
    fi
}

# ==============================================================================
# Panel Registration
# ==============================================================================
# Non-`box install` Docker apps use panel_register_app (which handles icon
# download + profiles.py class write in one shot) rather than emby.sh's
# _add_panel_meta (which assumes a `box install`-created base class exists
# to subclass with urloverride).
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
_install_aiostreams() {
    mkdir -p "$app_datadir"
    chown -R "${user}:${user}" "$app_dir"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    swizdb set "${app_name}/port" "$app_port"
    swizdb set "${app_name}/channel" "$app_channel"

    # ==========================================================================
    # Generate secrets (or restore if re-installing without --remove)
    # ==========================================================================
    local secret_key addon_password addon_id aiostreams_auth
    addon_password="" aiostreams_auth=""
    if [[ -f "${app_dir}/.env" ]] && grep -q "^SECRET_KEY=" "${app_dir}/.env"; then
        echo_info "Reusing existing SECRET_KEY and credentials from ${app_dir}/.env"
        secret_key=$(grep "^SECRET_KEY=" "${app_dir}/.env" | cut -d'=' -f2- | tr -d '"')
        addon_password=$(grep "^ADDON_PASSWORD=" "${app_dir}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        addon_id=$(grep "^ADDON_ID=" "${app_dir}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        aiostreams_auth=$(grep "^AIOSTREAMS_AUTH=" "${app_dir}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
    else
        secret_key=$(openssl rand -hex 32)
        addon_id="aiostreams.$(hostname -s | tr '[:upper:]' '[:lower:]').local"
    fi

    # ==========================================================================
    # BASE_URL = https://<subdomain>
    # ==========================================================================
    local base_url="https://${app_domain}"

    # ==========================================================================
    # Auth (channel-aware)
    # ==========================================================================
    # The subdomain is publicly reachable (Stremio clients need direct,
    # unauthenticated access to per-user addon/stream endpoints), so protection
    # is enforced inside AIOStreams rather than at nginx:
    #   • stable  (:latest, <=2.29.x): ADDON_PASSWORD gates config creation.
    #   • nightly (:nightly, v2.30+):  AIOSTREAMS_AUTH session login gates the
    #     /stremio/configure page; a pre-existing ADDON_PASSWORD is migrated to a
    #     managed config access key on first boot.
    if [[ "$app_channel" == "nightly" ]]; then
        if [[ -z "$aiostreams_auth" ]]; then
            if [[ "${AIOSTREAMS_AUTH+set}" = "set" ]]; then
                # Env explicitly set (even to empty) — respect the user's choice
                aiostreams_auth="${AIOSTREAMS_AUTH}"
            else
                aiostreams_auth="$(_gen_aiostreams_auth)"
                echo_info "Generated AIOStreams login (also written to ${app_dir}/.env):"
                echo_info "  user:     ${aiostreams_auth%%:*}"
                echo_info "  password: ${aiostreams_auth#*:}"
            fi
        fi
        if [[ -z "$aiostreams_auth" ]]; then
            echo_warn "AIOSTREAMS_AUTH is empty — the configure page will NOT be"
            echo_warn "login-protected. Set it in ${app_dir}/.env later and restart."
        fi
    else
        if [[ -z "$addon_password" ]]; then
            if [[ "${AIOSTREAMS_ADDON_PASSWORD+set}" = "set" ]]; then
                # Env explicitly set (even to empty) — respect the user's choice
                addon_password="${AIOSTREAMS_ADDON_PASSWORD}"
            else
                echo ""
                echo_info "AIOStreams (stable) ships with ADDON_PASSWORD as its only"
                echo_info "built-in auth. The subdomain is publicly reachable, so a"
                echo_info "password is strongly recommended. We'll auto-generate a"
                echo_info "strong one unless you provide your own."
                read -r -p "Set an addon password (Enter to auto-generate): " addon_password </dev/tty || true
                if [[ -z "$addon_password" ]]; then
                    addon_password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c -24)
                    echo_info "Auto-generated addon password (also written to ${app_dir}/.env): ${addon_password}"
                fi
            fi
        fi
        if [[ -z "$addon_password" ]]; then
            echo_warn "ADDON_PASSWORD is empty — anyone with the URL can configure"
            echo_warn "your addon. Set it in ${app_dir}/.env later and restart."
        fi
    fi

    # ==========================================================================
    # Auto-detect local services (StremThru proxy support)
    # ==========================================================================
    local stremthru_url=""
    if [[ -f /install/.stremthru.lock ]]; then
        local st_port
        st_port=$(swizdb get "stremthru/port" 2>/dev/null) || true
        if [[ -n "$st_port" ]]; then
            stremthru_url="http://127.0.0.1:${st_port}"
            echo_info "Detected StremThru on port ${st_port} — can be used as Stremio addon proxy"
        fi
    fi

    # ==========================================================================
    # Generate .env file (single source of truth, mounted into container)
    # ==========================================================================
    echo_progress_start "Generating environment file"

    cat >"${app_dir}/.env" <<EOF
# AIOStreams configuration
# Generated by swizzin aiostreams.sh installer on $(date -Iseconds)
# Channel: ${app_channel} (image ${app_image})

# --- Identity ---
ADDON_NAME="AIOStreams"
ADDON_ID="${addon_id}"

# --- Network ---
PORT=${app_container_port}
BASE_URL=${base_url}

# --- Security ---
# 64-character hex secret — DO NOT regenerate without --remove first
SECRET_KEY=${secret_key}
EOF

    if [[ "$app_channel" == "nightly" ]]; then
        cat >>"${app_dir}/.env" <<EOF

# Operator login (v2.30+). Session login gating the /stremio/configure page.
# Comma-separated user:password pairs.
AIOSTREAMS_AUTH=${aiostreams_auth}
# Which of the above users are admins (configure page + admin-only endpoints).
AIOSTREAMS_AUTH_ADMINS=${aiostreams_auth%%:*}
EOF
        if [[ -n "$addon_password" ]]; then
            cat >>"${app_dir}/.env" <<EOF

# Deprecated on nightly: migrated into the managed config access key on first
# boot. Kept for one startup after upgrading from the stable channel.
ADDON_PASSWORD=${addon_password}
EOF
        fi
    else
        cat >>"${app_dir}/.env" <<EOF

# Addon password (comma-separated for multiple). Empty disables password protection.
ADDON_PASSWORD=${addon_password}
EOF
    fi

    # Add StremThru hint as a comment (AIOStreams configures providers via UI)
    if [[ -n "$stremthru_url" ]]; then
        cat >>"${app_dir}/.env" <<EOF

# --- Detected local services (configure in AIOStreams UI) ---
# StremThru proxy detected at: ${stremthru_url}
# Use this URL when configuring "Stream Proxy" in the AIOStreams web UI
# or via the marketplace.
EOF
    fi

    # Secure: contains SECRET_KEY
    chmod 600 "${app_dir}/.env"
    chown root:root "${app_dir}/.env"

    echo_progress_done "Environment file generated"

    # ==========================================================================
    # Generate docker-compose.yml
    # ==========================================================================
    echo_progress_start "Generating Docker Compose configuration"

    # Resource limits (override via env vars)
    local cpu_limit="${DOCKER_CPU_LIMIT:-2}"
    local mem_limit="${DOCKER_MEM_LIMIT:-2G}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-256M}"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  aiostreams:
    image: ${app_image}
    container_name: aiostreams
    restart: unless-stopped
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${app_port}:${app_container_port}"
    env_file:
      - ${app_dir}/.env
    volumes:
      - ${app_datadir}:/app/data
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
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:${app_container_port}/api/v1/status >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
COMPOSE

    chmod 644 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"

    # ==========================================================================
    # Pull image + start container
    # ==========================================================================
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

    # Stash credentials for post-install info (avoid re-reading .env later)
    _aiostreams_addon_password="${addon_password}"
    _aiostreams_auth="${aiostreams_auth}"
    _aiostreams_channel="${app_channel}"
    _aiostreams_base_url="${base_url}"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_aiostreams() {
    echo_progress_start "Installing systemd service"

    local mem_max="${SYSTEMD_MEM_MAX:-2G}"
    local cpu_quota="${SYSTEMD_CPU_QUOTA:-200%}"
    local tasks_max="${SYSTEMD_TASKS_MAX:-2048}"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Stremio super-addon)
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
# Subdomain Vhost Creation (matches emby.sh / plex.sh / seerr.sh)
# ==============================================================================
# AIOStreams is a Next.js SPA with root-absolute asset paths (/_next/static/*).
# Subpath via sub_filter is unreliable for SPA chunk loading, so we ship
# subdomain-only — no _create_subfolder_config equivalent.
# ==============================================================================

_create_subdomain_vhost() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local organizr_domain
    organizr_domain=$(_get_organizr_domain)

    echo_progress_start "Creating subdomain nginx vhost"

    # Clean up any legacy subfolder config from older installs (pre-refactor)
    if [ -f "$subfolder_conf" ]; then
        _backup_file "$subfolder_conf"
        rm -f "$subfolder_conf"
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

    ${csp_header}

    # Stream resolution from upstream addons can take a while when fanning out
    # to many indexers/debrid providers; bump proxy timeouts accordingly.
    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
VHOST

    [ -L "$subdomain_enabled" ] || ln -s "$subdomain_vhost" "$subdomain_enabled"

    _nginx_config_written="$subdomain_vhost"

    echo_progress_done "Subdomain vhost created"
}

# ==============================================================================
# Subdomain Install Entry Point (matches emby.sh _install_subdomain)
# ==============================================================================
# State machine:
#   not_installed → docker install → container up → systemd → cert → vhost → panel meta
#   unknown       → cert → vhost → panel meta (heals partial installs)
#   subdomain     → no-op (already configured)
# ==============================================================================

_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${AIOSTREAMS_LE_HOSTNAME:-$domain}"
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
            _install_aiostreams
            _systemd_aiostreams
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
    echo_info "Web UI:  ${_aiostreams_base_url:-https://${app_domain}/}"
    echo_info "Local:   http://127.0.0.1:${app_port}/"
    echo_info "Channel: ${_aiostreams_channel:-stable} (${app_image})"
    if [[ "${_aiostreams_channel:-stable}" == "nightly" ]]; then
        if [[ -n "${_aiostreams_auth:-}" ]]; then
            echo_info "Login (configure page) — user: ${_aiostreams_auth%%:*}  password: ${_aiostreams_auth#*:}"
        else
            echo_warn "No AIOSTREAMS_AUTH set — the configure page is NOT login-protected."
            echo_warn "Set AIOSTREAMS_AUTH in ${app_dir}/.env, then: systemctl restart ${app_servicefile}"
        fi
    else
        if [[ -n "${_aiostreams_addon_password:-}" ]]; then
            echo_info "Addon password: ${_aiostreams_addon_password}"
        else
            echo_warn "No addon password set — anyone with the URL can use your addon."
            echo_warn "Set ADDON_PASSWORD in ${app_dir}/.env to enable protection,"
            echo_warn "then run: systemctl restart ${app_servicefile}"
        fi
    fi
    echo ""
    echo_info "Configuration: open the web UI, configure debrid + addons + filters,"
    echo_info "then click 'Save & Install' to get your personal addon URL."
    echo ""
    echo_info "Logs:    docker logs -f aiostreams"
    echo_info "Config:  ${app_dir}/.env"
    echo_info "Data:    ${app_datadir}"
    echo ""
}

# ==============================================================================
# Update
# ==============================================================================
_update_aiostreams() {
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

    # On nightly, ensure the configure page is login-protected (AIOSTREAMS_AUTH).
    if [[ "$app_channel" == "nightly" && -f "${app_dir}/.env" ]] && ! grep -q "^AIOSTREAMS_AUTH=" "${app_dir}/.env"; then
        local _auth
        _auth="$(_gen_aiostreams_auth)"
        {
            echo ""
            echo "# Operator login (v2.30+). Session login gating /stremio/configure."
            echo "AIOSTREAMS_AUTH=${_auth}"
            echo "AIOSTREAMS_AUTH_ADMINS=${_auth%%:*}"
        } >>"${app_dir}/.env"
        echo_info "Added AIOStreams login — user: ${_auth%%:*}  password: ${_auth#*:}"
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
_remove_aiostreams() {
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
    # Legacy subpath app config (in case an earlier install used it)
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing legacy subpath nginx app config"
        if command -v _remove_nginx_conf >/dev/null 2>&1; then
            _remove_nginx_conf "$app_name"
        else
            rm -f "/etc/nginx/apps/${app_name}.conf"
        fi
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Legacy subpath nginx app config removed"
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
    else
        echo_info "Configuration kept at: ${app_dir}/.env"
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
    echo "  --latest                Use the nightly channel (:nightly, v2.30+ login auth)"
    echo "  --update [--latest]     Pull image and recreate (add --latest to switch to nightly)"
    echo "  --remove [--force]      Complete removal (prompts to purge config)"
    echo "  --register-panel        Re-register with swizzin panel"
    echo ""
    echo "Environment variable overrides:"
    echo "  AIOSTREAMS_DOMAIN          Subdomain for AIOStreams (e.g. aiostreams.example.com)"
    echo "  AIOSTREAMS_LE_INTERACTIVE  yes|no — interactive Let's Encrypt mode (default: no)"
    echo "  AIOSTREAMS_USE_LATEST_TAG  true — same as --latest (nightly channel)"
    echo "  AIOSTREAMS_ADDON_PASSWORD  Set addon password unattended (stable channel)"
    echo "  AIOSTREAMS_AUTH            user:pass[,user2:pass2] login (nightly channel)"
    echo "  AIOSTREAMS_AUTH_USER       Username for generated nightly login (default: owner)"
    echo "  AIOSTREAMS_AUTH_PASSWORD   Password for generated nightly login"
    echo "  DOCKER_CPU_LIMIT           Compose CPU limit (default: 2)"
    echo "  DOCKER_MEM_LIMIT           Compose memory limit (default: 2G)"
    echo "  DOCKER_MEM_RESERVE         Compose memory reservation (default: 256M)"
    echo "  SYSTEMD_MEM_MAX            Systemd MemoryMax (default: 2G)"
    echo "  SYSTEMD_CPU_QUOTA          Systemd CPUQuota (default: 200%)"
    exit 1
}

# ==============================================================================
# Main
# ==============================================================================

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
        --latest) AIOSTREAMS_USE_LATEST_TAG="true" ;;
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
        _update_aiostreams
        ;;
    "--remove")
        _remove_aiostreams "${2:-}"
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        app_domain="$(_get_domain)"
        if [[ -z "$app_domain" ]]; then
            echo_error "No domain stored in swizdb for ${app_name}. Run the installer first or set AIOSTREAMS_DOMAIN."
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
# All paths funnel through _install_subdomain (matches emby.sh/plex.sh/seerr.sh).
# The state machine inside handles fresh installs, partial-install healing
# (lock exists but no vhost — e.g. DNS wasn't pointed on first run), and
# already-configured no-ops.
# ==============================================================================
_cleanup_needed=true
_install_subdomain
# _install_subdomain sets _cleanup_needed=false on success
