#!/bin/bash
set -euo pipefail
# silo installer
# STiXzoOR 2026
# Usage: bash silo.sh [--update [--verbose]|--remove [--force]|--register-panel|--jf-subdomain [--revert]|--status]
#
# Subdomain-only — upstream recommends "a dedicated hostname at its root" and
# has no base-path setting, so a subfolder install is not offered.
# Set SILO_DOMAIN env var to skip the interactive domain prompt.
#
# Silo — self-hosted media server (Go backend, React UI) with Jellyfin- and
# Audiobookshelf-compatible APIs, so existing Jellyfin/Emby clients can connect.
#
# Upstream: https://github.com/Silo-Server/silo-server
# Docs:     https://siloserver.org/docs/install
# Image:    ghcr.io/silo-server/silo-server:latest (prerelease, built from main)
#           + pgvector/pgvector:pg18 + redis:alpine in one compose project
#
# What the installer configures:
#   - PostgreSQL (pgvector) and Redis sidecars on the compose network only —
#     no host ports, so they never collide with other local postgres/redis
#   - SECRET_KEY + database password generated once (${app_dir}/.env, 600).
#     Back up SECRET_KEY separately: losing it makes encrypted secrets unrecoverable
#   - PostgreSQL auto-tuning bounded to an explicit memory budget (upstream's
#     "auto" sizes to 75% of the HOST's RAM, which is wrong on a shared box)
#   - Web UI and the Jellyfin/Audiobookshelf compat listeners on 127.0.0.1 only
#     (the compat default 8096 is Emby/Jellyfin's port, so it gets its own)
#   - Media mounted read-only (rslave) at the same path inside the container
#   - Admin account claimed via the API before the vhost goes live — Silo's
#     first-run setup has no secret, so whoever reaches it first owns the server
#   - Public URL set to https://<domain>
#   - VA-API passthrough when /dev/dri/renderD128 exists
# No libraries are created: add them in the web UI (a first scan of a large
# FUSE-backed library is heavy — pick the folders deliberately).

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
app_name="silo"
app_pretty="Silo"
app_lockname="${app_name}"
app_icon_name="${app_name}"
app_icon_url="https://raw.githubusercontent.com/Silo-Server/silo-server/main/web/public/web-app-icon-512.png"

app_image="${SILO_IMAGE:-ghcr.io/silo-server/silo-server:latest}"
# Postgres major pinned to upstream's compose — a major bump needs a dump/restore
db_image="pgvector/pgvector:pg18"
redis_image="redis:alpine"

app_dir="/opt/silo"
app_envfile="${app_dir}/.env"
app_admin_file="${app_dir}/.admin_credentials"
app_dbdir="${app_dir}/postgres"
app_redisdir="${app_dir}/redis"
app_dumpdir="${app_dir}/db-dumps"
app_servicefile="${app_name}.service"
# Host bind-mount subdirs (container path in upstream's compose)
app_datadirs=(plugins artwork compat transcode download-artifacts)

# Media exposed to Silo, at the same path inside the container so library
# paths match what Emby/the arrs see
media_root="${SILO_MEDIA_ROOT:-/mnt}"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"

# ==============================================================================
# Port Allocation (web UI + Jellyfin compat + Audiobookshelf compat)
# ==============================================================================
# `port` only skips ports that are already listening, so back-to-back calls
# can hand out the same one — re-roll until it differs from the ones taken.
_alloc_port() {
    local key="$1"
    shift
    local p taken
    if p="$(swizdb get "${app_name}/${key}" 2>/dev/null)" && [[ -n "$p" ]]; then
        echo "$p"
        return
    fi
    while :; do
        p=$(port 10000 12000)
        for taken in "$@"; do
            [[ "$p" == "$taken" ]] && continue 2
        done
        echo "$p"
        return
    done
}

app_port=$(_alloc_port port)
jf_port=$(_alloc_port jf_port "$app_port")
abs_port=$(_alloc_port abs_port "$app_port" "$jf_port")

# ==============================================================================
# Domain Resolution (subdomain only — see header)
# ==============================================================================
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
# Optional second hostname for the Jellyfin compat API (client apps)
jf_vhost="/etc/nginx/sites-available/${app_name}-jf"
jf_enabled="/etc/nginx/sites-enabled/${app_name}-jf"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "${app_name}/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${SILO_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${SILO_DOMAIN:-}" ]; then
        echo_info "Using domain from SILO_DOMAIN: $SILO_DOMAIN"
        app_domain="$SILO_DOMAIN"
        swizdb set "${app_name}/domain" "$app_domain"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for ${app_pretty}" "[$existing_domain]"
    else
        echo_query "Enter domain for ${app_pretty}" "(e.g., silo.example.com)"
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
    export SILO_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${SILO_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from SILO_LE_INTERACTIVE: $SILO_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export SILO_LE_INTERACTIVE="yes"
    else
        export SILO_LE_INTERACTIVE="no"
    fi
}

_request_certificate() {
    local domain="$1"
    local le_hostname="${SILO_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${SILO_LE_INTERACTIVE:-no}"

    if [ -f "${cert_dir}/fullchain.pem" ]; then
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

    # `box install letsencrypt` can exit 0 after a failed http-01 challenge and
    # leave an empty cert dir behind, so trust the file, not the exit code
    if [ $result -ne 0 ] || [ ! -f "${cert_dir}/fullchain.pem" ]; then
        rmdir "$cert_dir" 2>/dev/null || true
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
# State Detection
# ==============================================================================
# No subfolder mode, so: not_installed | subdomain | unknown (lock without vhost,
# e.g. cert issuance failed because DNS wasn't pointed yet).
_get_install_state() {
    if [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo "not_installed"
    elif [ -f "$subdomain_vhost" ]; then
        echo "subdomain"
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
# .env Helpers (secrets + Silo settings; compose reads it via env_file)
# ==============================================================================
# Set KEY=VALUE in the env file, replacing an existing line. Values are written
# verbatim (docker compose env_file does not interpret quotes the shell way).
_env_set() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp "${app_dir}/.env.XXXXXX")
    if [[ -f "$app_envfile" ]]; then
        grep -v "^${key}=" "$app_envfile" >"$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$app_envfile"
}

# Set KEY only when absent — keeps user edits across re-runs and updates
_env_default() {
    local key="$1" value="$2"
    if [[ -f "$app_envfile" ]] && grep -q "^${key}=" "$app_envfile"; then
        return 0
    fi
    _env_set "$key" "$value"
}

_env_get() {
    local key="$1"
    [[ -f "$app_envfile" ]] || return 0
    grep "^${key}=" "$app_envfile" | tail -n1 | cut -d= -f2- || true
}

# Generate (once) secrets and seed every installer-managed setting. Existing
# keys are never overwritten, so re-runs and `--update` are safe.
_write_env() {
    touch "$app_envfile"
    chmod 600 "$app_envfile"
    chown root:root "$app_envfile"

    # Hex keeps the password URL-safe inside DATABASE_URL
    _env_default POSTGRES_USER "silo"
    _env_default POSTGRES_DB "silo"
    _env_default POSTGRES_PASSWORD "$(openssl rand -hex 24)"
    _env_default SECRET_KEY "$(openssl rand -base64 48 | tr -d '\n')"

    # Silo tunes PostgreSQL itself (ALTER SYSTEM at startup). Bound it to the
    # postgres container's budget instead of upstream's 75%-of-host default.
    _env_default POSTGRES_TUNE "auto"
    _env_default POSTGRES_TUNE_MEMORY "${SILO_PG_MEMORY:-2GB}"
    _env_default POSTGRES_TUNE_STORAGE "ssd"
    _env_default POSTGRES_TUNE_CPUS "2"
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
# Installer-owned artifact — regenerated on install and update. Secrets live in
# .env: postgres gets only its own values (interpolated), silo reads the file.
_write_compose() {
    local cpu_limit="${DOCKER_CPU_LIMIT:-6}"
    local mem_limit="${DOCKER_MEM_LIMIT:-6G}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-512M}"
    local pg_mem_limit="${SILO_PG_MEM_LIMIT:-3G}"
    local pg_shm="${SILO_PG_SHM_SIZE:-1g}"

    # Hardware transcoding: pass the render node through when the host has one
    local gpu_block=""
    if [[ -e /dev/dri/renderD128 ]]; then
        local render_gid
        render_gid=$(stat -c '%g' /dev/dri/renderD128)
        gpu_block="    devices:
      - /dev/dri:/dev/dri
    group_add:
      - \"${render_gid}\""
    fi

    local data_mounts="" d
    for d in "${app_datadirs[@]}"; do
        case "$d" in
            transcode) data_mounts+="      - ${app_dir}/${d}:/tmp/silo-transcode"$'\n' ;;
            download-artifacts) data_mounts+="      - ${app_dir}/${d}:/tmp/silo-download-artifacts"$'\n' ;;
            *) data_mounts+="      - ${app_dir}/${d}:/var/lib/silo/${d}"$'\n' ;;
        esac
    done

    # Container listeners stay at upstream's fixed 8080/8096/13378; only the
    # host side is remapped. /proc mounts let Silo report its cgroup's share.
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  silo:
    image: ${app_image}
    container_name: silo
    restart: unless-stopped
    stop_grace_period: 2m
    env_file: .env
    environment:
      MODE: integrated
      PORT: "8080"
      JF_PORT: "8096"
      DATABASE_URL: postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@silo-postgres:5432/\${POSTGRES_DB}?sslmode=disable
      REDIS_URL: redis://silo-redis:6379
      SILO_PLUGIN_CACHE_DIR: /var/lib/silo/plugins
    ports:
      - "127.0.0.1:${app_port}:8080"
      - "127.0.0.1:${jf_port}:8096"
      - "127.0.0.1:${abs_port}:13378"
    volumes:
      - ${media_root}:${media_root}:ro,rslave
${data_mounts}      - /proc/meminfo:/host/proc/meminfo:ro
      - /proc/stat:/host/proc/stat:ro
      - /proc/loadavg:/host/proc/loadavg:ro
${gpu_block}
    depends_on:
      silo-postgres:
        condition: service_healthy
        restart: true
      silo-redis:
        condition: service_healthy
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
        reservations:
          memory: ${mem_reserve}
    security_opt:
      - no-new-privileges:true

  silo-postgres:
    image: ${db_image}
    container_name: silo-postgres
    restart: unless-stopped
    shm_size: ${pg_shm}
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ${app_dbdir}:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \$\${POSTGRES_USER}"]
      interval: 5s
      timeout: 3s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: ${pg_mem_limit}

  silo-redis:
    image: ${redis_image}
    container_name: silo-redis
    restart: unless-stopped
    volumes:
      - ${app_redisdir}:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 512M
COMPOSE

    chmod 644 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"
}

# ==============================================================================
# API Helpers
# ==============================================================================
_base="http://127.0.0.1:${app_port}"

# Migrations run before the listener starts and can take minutes on a large
# library (the image's own healthcheck allows 20), so wait generously.
_wait_for_silo() {
    local timeout="${1:-600}" i
    echo_progress_start "Waiting for ${app_pretty} to come up (migrations run first)"
    for ((i = 0; i < timeout; i += 3)); do
        if curl -sf --max-time 5 "${_base}/api/v1/health" >/dev/null 2>&1; then
            echo_progress_done "${app_pretty} is responding"
            return 0
        fi
        sleep 3
    done
    echo_error "${app_pretty} did not respond within ${timeout}s (docker logs silo)"
    exit 1
}

_setup_field() {
    curl -sf --max-time 10 -H "Accept: application/json" "${_base}/api/v2/system/setup" 2>/dev/null \
        | python3 -c "import json,sys; print(str(json.load(sys.stdin).get(sys.argv[1], '')).lower())" "$1" 2>/dev/null || true
}

# The swizzin master user's password (swizzin keeps "user:pass" in
# /root/.master.info), so the login matches the arrs. Empty when the owner
# isn't the master user or the file is missing.
_master_password() {
    local mu mp
    [[ -r /root/.master.info ]] || return 0
    IFS=: read -r mu mp </root/.master.info || true
    [[ "$mu" == "$user" ]] && printf '%s' "$mp"
    return 0
}

# Claim the first admin (master user + master password, else generated) and set
# the public URL. Must run before the vhost exists — setup is first-come.
_create_admin() {
    local domain="$1"
    if [[ "$(_setup_field needs_setup)" != "true" ]]; then
        echo_info "Admin account already exists — skipping"
        return 0
    fi

    local admin_user="${SILO_ADMIN_USER:-$user}"
    local admin_pass="${SILO_ADMIN_PASSWORD:-}"
    local admin_email="${SILO_ADMIN_EMAIL:-${admin_user}@${domain}}"
    [[ -z "$admin_pass" && "$admin_user" == "$user" ]] && admin_pass="$(_master_password)"
    # Silo requires 8..72 bytes
    if [[ ${#admin_pass} -lt 8 || ${#admin_pass} -gt 72 ]]; then
        [[ -n "$admin_pass" ]] && echo_warn "Master password does not meet Silo's 8-72 character rule — generating one"
        admin_pass="$(openssl rand -hex 12)"
    fi

    local body_file resp_file code
    body_file=$(mktemp)
    resp_file=$(mktemp)
    chmod 600 "$body_file" "$resp_file"
    python3 -c "import json,sys
print(json.dumps({'username': sys.argv[1], 'email': sys.argv[2], 'password': sys.argv[3], 'create_default_profile': True}))" \
        "$admin_user" "$admin_email" "$admin_pass" >"$body_file"
    code=$(curl -sS --max-time 30 -o "$resp_file" -w '%{http_code}' \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -d @"$body_file" "${_base}/api/v2/auth/setup" 2>>"$log") || true
    rm -f "$body_file"

    if [[ "$code" != "201" ]]; then
        echo_warn "Admin setup failed (HTTP ${code:-none}): $(head -c 300 "$resp_file")"
        rm -f "$resp_file"
        echo_error "Refusing to expose an unclaimed server — finish setup locally (ssh -L ${app_port}:127.0.0.1:${app_port}), then re-run"
        exit 1
    fi

    umask 077
    printf 'username=%s\npassword=%s\nemail=%s\n' "$admin_user" "$admin_pass" "$admin_email" >"$app_admin_file"
    chmod 600 "$app_admin_file"
    chown root:root "$app_admin_file"
    echo_info "Admin account '${admin_user}' created (credentials in ${app_admin_file})"

    local token
    token=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['access_token'])" "$resp_file" 2>/dev/null) || true
    rm -f "$resp_file"
    [[ -n "$token" ]] || return 0
    if _put_settings "$token" "server.public_url" "https://${domain}"; then
        _verbose "Public URL set to https://${domain}"
    else
        echo_warn "Could not set the public URL — set it in Admin > Server > General"
    fi
}

# Access token for the stored admin (empty when credentials are missing/wrong)
_admin_token() {
    [[ -f "$app_admin_file" ]] || return 0
    local body
    body=$(python3 -c "import json,sys
d=dict(l.rstrip('\\n').split('=', 1) for l in open(sys.argv[1]) if '=' in l)
print(json.dumps({'username': d['username'], 'password': d['password']}))" "$app_admin_file" 2>/dev/null) || return 0
    printf '%s' "$body" | curl -s --max-time 20 -H "Content-Type: application/json" -H "Accept: application/json" \
        -d @- "${_base}/api/v2/auth/login" 2>>"$log" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || true
}

# Write one server setting. Settings writes are optimistic-concurrency: the
# store's ETag must be echoed back as If-Match.
_put_settings() {
    local token="$1" key="$2" value="$3" cfg etag body rc=1
    cfg=$(mktemp)
    chmod 600 "$cfg"
    printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n' "$token" >"$cfg"
    etag=$(curl -s --max-time 20 --config "$cfg" -D - -o /dev/null "${_base}/api/v2/admin/settings" 2>>"$log" \
        | awk -F': ' 'tolower($1) == "etag" {print $2}' | tr -d '\r') || true
    body=$(python3 -c "import json,sys; print(json.dumps({'values': {sys.argv[1]: sys.argv[2]}}))" "$key" "$value")
    if [[ -n "$etag" ]] && curl -sf --max-time 20 --config "$cfg" -X PUT -H "If-Match: ${etag}" \
        -H "Content-Type: application/json" -d "$body" "${_base}/api/v2/admin/settings" >/dev/null 2>>"$log"; then
        rc=0
    fi
    rm -f "$cfg"
    return "$rc"
}

# ==============================================================================
# App Installation
# ==============================================================================
_compose() {
    docker compose -f "${app_dir}/docker-compose.yml" "$@"
}

_install_silo() {
    local domain="$1" d

    if [[ ! -d "$media_root" ]]; then
        echo_error "Media root ${media_root} does not exist (set SILO_MEDIA_ROOT)"
        exit 1
    fi

    mkdir -p "$app_dir" "$app_dbdir" "$app_redisdir" "$app_dumpdir"
    for d in "${app_datadirs[@]}"; do
        mkdir -p "${app_dir}/${d}"
    done

    swizdb set "${app_name}/port" "$app_port"
    swizdb set "${app_name}/jf_port" "$jf_port"
    swizdb set "${app_name}/abs_port" "$abs_port"

    _write_env

    echo_progress_start "Generating Docker Compose configuration"
    _write_compose
    _compose config --quiet >>"$log" 2>&1 || {
        echo_error "Generated docker-compose.yml is invalid (see $log)"
        exit 1
    }
    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling ${app_pretty} Docker images"
    _compose pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker images"
        exit 1
    }
    echo_progress_done "Docker images pulled"

    echo_progress_start "Starting ${app_pretty} containers"
    _compose up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "${app_pretty} containers started"

    _wait_for_silo

    # The first boot writes the tuned settings via ALTER SYSTEM; shared_buffers
    # and friends only take effect after a postgres restart (silo follows it)
    echo_progress_start "Restarting PostgreSQL to apply tuned settings"
    _compose restart silo-postgres >>"$log" 2>&1 || true
    echo_progress_done "PostgreSQL restarted"
    # Let silo notice and restart before polling, or the old process answers
    sleep 10
    _wait_for_silo

    _create_admin "$domain"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_silo() {
    echo_progress_start "Installing systemd service"

    local mem_max="${SYSTEMD_MEM_MAX:-10G}"
    local cpu_quota="${SYSTEMD_CPU_QUOTA:-800%}"
    local tasks_max="${SYSTEMD_TASKS_MAX:-4096}"

    # Stop waits for silo's 2m stop_grace_period (drains in-flight requests)
    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (media server)
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
TimeoutStartSec=300
TimeoutStopSec=180

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
# Subdomain Vhost Creation
# ==============================================================================
_create_subdomain_vhost() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local organizr_domain
    organizr_domain=$(_get_organizr_domain)

    echo_progress_start "Creating subdomain nginx vhost"

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

    # Streaming server: no buffering either way (seeking needs Range passed
    # straight through), long timeouts for transcodes, WebSockets for live
    # updates, unlimited uploads (subtitles, artwork).
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
    proxy_request_buffering off;

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

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
VHOST

    [ -L "$subdomain_enabled" ] || ln -s "$subdomain_vhost" "$subdomain_enabled"

    _nginx_config_written="$subdomain_vhost"

    echo_progress_done "Subdomain vhost created"
}

# ==============================================================================
# Jellyfin Compat Hostname (--jf-subdomain)
# ==============================================================================
# Jellyfin/Emby client apps (Infuse, Swiftfin, Jellyfin apps) talk to the
# compat listener, not the web UI, so it gets its own hostname — upstream:
# "publish only the ports users need, each on its own hostname".
_create_jf_vhost() {
    local domain="$1"
    local cert_dir="/etc/nginx/ssl/$domain"

    echo_progress_start "Creating Jellyfin compat nginx vhost"
    cat >"$jf_vhost" <<VHOST
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
    proxy_request_buffering off;

    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    location / {
        proxy_pass http://127.0.0.1:${jf_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;

        # /socket (Jellyfin client WebSocket)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
VHOST
    [ -L "$jf_enabled" ] || ln -s "$jf_vhost" "$jf_enabled"
    echo_progress_done "Jellyfin compat vhost created"
}

_set_jf_public_url() {
    local url="$1" token
    token=$(_admin_token)
    if [[ -n "$token" ]] && _put_settings "$token" "jellyfin_compat.public_url" "$url"; then
        echo_info "Jellyfin compat public URL set to ${url}"
    else
        echo_warn "Could not set the Jellyfin compat public URL — set it in Admin > Settings"
    fi
}

_jf_subdomain() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    if [[ "${1:-}" == "--revert" ]]; then
        rm -f "$jf_enabled" "$jf_vhost"
        _reload_nginx
        _set_jf_public_url "http://127.0.0.1:${jf_port}"
        swizdb clear "${app_name}/jf_domain" 2>/dev/null || true
        echo_success "Jellyfin compat hostname removed (listener stays on 127.0.0.1:${jf_port})"
        exit 0
    fi

    local domain="${SILO_JF_DOMAIN:-}"
    [[ -n "$domain" ]] || domain=$(swizdb get "${app_name}/jf_domain" 2>/dev/null) || true
    if [[ -z "$domain" ]]; then
        echo_query "Enter hostname for Jellyfin/Emby client apps" "(e.g., silo-jf.example.com)"
        read -r domain </dev/tty || true
    fi
    if [[ -z "$domain" || ! "$domain" =~ \. || "$domain" =~ [[:space:]] ]]; then
        echo_error "A valid hostname is required (set SILO_JF_DOMAIN)"
        exit 1
    fi
    if [[ "$domain" == "$(_get_domain)" ]]; then
        echo_error "The client hostname must differ from the web UI hostname"
        exit 1
    fi
    swizdb set "${app_name}/jf_domain" "$domain"

    # The LE hostname override belongs to the web UI hostname only
    SILO_LE_HOSTNAME="" _request_certificate "$domain"
    _create_jf_vhost "$domain"
    _reload_nginx
    _set_jf_public_url "https://${domain}"

    echo_success "Jellyfin/Emby clients can connect to https://${domain} (port 443)"
    exit 0
}

# ==============================================================================
# Subdomain Install Entry Point
# ==============================================================================
# State machine:
#   not_installed → docker → containers/env/admin → systemd → cert → vhost → panel
#   unknown       → cert → vhost → panel (heals partial installs)
#   subdomain     → no-op (already configured)
_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${SILO_LE_HOSTNAME:-$domain}"
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
            _install_silo "$domain"
            _systemd_silo
            ;& # fallthrough to subdomain setup
        "unknown")
            _request_certificate "$domain"
            if [ -f "/install/.nginx.lock" ]; then
                _create_subdomain_vhost "$domain" "$le_hostname"
                _reload_nginx
                _register_panel "$domain"
                _exclude_from_organizr
            else
                echo_info "nginx not installed — skipping vhost and panel registration"
            fi

            touch "/install/.${app_lockname}.lock"
            _lock_file_created="/install/.${app_lockname}.lock"
            _cleanup_needed=false

            _post_install_info "$domain"
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
    local domain="$1"
    echo ""
    echo_info "Web UI:   https://${domain}/"
    echo_info "Local:    http://127.0.0.1:${app_port}/"
    if [[ -f "$app_admin_file" ]]; then
        echo_info "Admin:    $(grep '^username=' "$app_admin_file" | cut -d= -f2-) (password: cat ${app_admin_file})"
    fi
    echo ""
    echo_info "Next: sign in, finish the wizard (Automatic storage) and add libraries"
    echo_info "  using container paths under ${media_root} (same paths as on the host)."
    echo ""
    echo_info "Compat listeners (localhost only — proxy them on their own hostname if needed):"
    echo_info "  Jellyfin/Emby clients: 127.0.0.1:${jf_port}   Audiobookshelf: 127.0.0.1:${abs_port}"
    echo ""
    echo_warn "Back up SECRET_KEY from ${app_envfile} separately — without it encrypted secrets are lost"
    echo_info "Logs:     docker logs -f silo"
    echo ""
}

# ==============================================================================
# Database dump (upstream requires a verified backup before every upgrade and
# guarantees no downgrade path)
# ==============================================================================
_dump_db() {
    local stamp out
    stamp=$(date +%Y%m%d-%H%M%S)
    out="${app_dumpdir}/silo-${stamp}.dump"
    mkdir -p "$app_dumpdir"
    chmod 700 "$app_dumpdir"
    echo_progress_start "Dumping database to ${out}"
    if ! _compose exec -T silo-postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' >"$out" 2>>"$log" \
        || ! [[ -s "$out" ]]; then
        rm -f "$out"
        echo_error "Database dump failed — not updating (see $log)"
        exit 1
    fi
    chmod 600 "$out"
    # Keep the three most recent dumps
    ls -1t "${app_dumpdir}"/silo-*.dump 2>/dev/null | tail -n +4 | xargs -r rm -f
    echo_progress_done "Database dumped ($(du -h "$out" | cut -f1))"
}

# ==============================================================================
# Update
# ==============================================================================
_update_silo() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."
    echo_warn "Silo is prerelease software: updates can run long migrations and cannot be rolled back in place"

    _dump_db

    # Regenerate compose (installer-owned); .env is preserved, new defaults seeded
    _write_env
    _write_compose

    echo_progress_start "Pulling latest ${app_pretty} images"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    _compose pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest images"
        exit 1
    }
    echo_progress_done "Latest images pulled"

    echo_progress_start "Recreating ${app_pretty} containers"
    _compose up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"

    _wait_for_silo 1200

    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_silo() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig
    if ask "Purge configuration, database, artwork and dumps? (media is never touched)" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    echo_progress_start "Stopping ${app_pretty} containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        _compose down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

    # pgvector/redis images may be shared with other stacks — only drop Silo's
    echo_progress_start "Removing Docker image"
    docker rmi "$app_image" >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    if [[ -L "$subdomain_enabled" ]] || [[ -f "$subdomain_vhost" ]] || [[ -f "$jf_vhost" ]]; then
        echo_progress_start "Removing subdomain vhosts"
        rm -f "$subdomain_enabled" "$subdomain_vhost" "$jf_enabled" "$jf_vhost"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Subdomain vhost removed"
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
        swizdb clear "${app_name}/jf_port" 2>/dev/null || true
        swizdb clear "${app_name}/abs_port" 2>/dev/null || true
        swizdb clear "${app_name}/domain" 2>/dev/null || true
        swizdb clear "${app_name}/jf_domain" 2>/dev/null || true
    else
        echo_info "Data kept at: ${app_dir}"
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
    echo "  (no args)                 Interactive setup"
    echo "  --update                  Dump the database, pull images and recreate containers"
    echo "  --remove [--force]        Complete removal (prompts to purge data)"
    echo "  --register-panel          Re-register with swizzin panel"
    echo "  --jf-subdomain [--revert] Expose the Jellyfin compat API for client apps on its own hostname"
    echo "  --status                  Show container and setup status"
    echo ""
    echo "Environment variable overrides:"
    echo "  SILO_DOMAIN                 Subdomain for Silo (e.g. silo.example.com)"
    echo "  SILO_LE_INTERACTIVE         yes|no — interactive Let's Encrypt mode (default: no)"
    echo "  SILO_LE_HOSTNAME            Request cert for a different hostname (e.g. wildcard)"
    echo "  SILO_JF_DOMAIN              Hostname for Jellyfin/Emby client apps (--jf-subdomain)"
    echo "  SILO_MEDIA_ROOT             Host media path mounted read-only (default: /mnt)"
    echo "  SILO_ADMIN_USER / _PASSWORD / _EMAIL"
    echo "                              Admin account (default: master user + its swizzin password)"
    echo "  SILO_IMAGE                  Pin a specific Silo image tag"
    echo "  SILO_PG_MEMORY              PostgreSQL tuning budget (default: 2GB)"
    echo "  SILO_PG_MEM_LIMIT / SILO_PG_SHM_SIZE"
    echo "  DOCKER_CPU_LIMIT / DOCKER_MEM_LIMIT / DOCKER_MEM_RESERVE"
    echo "  SYSTEMD_MEM_MAX / SYSTEMD_CPU_QUOTA"
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

_args=()
for arg in "$@"; do
    case "$arg" in
        --verbose) ;;
        *) _args+=("$arg") ;;
    esac
done
if [[ ${#_args[@]} -gt 0 ]]; then set -- "${_args[@]}"; else set --; fi

case "${1:-}" in
    "--update")
        _update_silo
        ;;
    "--remove")
        _remove_silo "${2:-}"
        ;;
    "--jf-subdomain")
        _jf_subdomain "${2:-}"
        ;;
    "--status")
        _compose ps 2>/dev/null || echo_warn "No compose project at ${app_dir}"
        echo_info "needs_setup=$(_setup_field needs_setup) wizard_completed=$(_setup_field wizard_completed)"
        exit 0
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        app_domain="$(_get_domain)"
        if [[ -z "$app_domain" ]]; then
            echo_error "No domain stored in swizdb for ${app_name}. Run the installer first or set SILO_DOMAIN."
            exit 1
        fi
        _register_panel "$app_domain"
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_pretty}"
        exit 0
        ;;
    "")
        ;;
    *)
        _usage
        ;;
esac

_cleanup_needed=true
_install_subdomain
