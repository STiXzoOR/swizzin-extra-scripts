#!/bin/bash
set -euo pipefail
# romm installer
# STiXzoOR 2026
# Usage: bash romm.sh [--update [--verbose]|--remove [--force]|--register-panel|--set-providers|--add-platforms <slugs>|--status]
#
# Subdomain-only — RomM's Vue SPA hardcodes "/" as its router base and talks to
# /api, /ws (socket.io), /netplay and /assets at the web root, and upstream has
# no base-path setting (rommapp/romm#1551, #1604). A subpath would need
# sub_filter over ~1500 hashed JS chunks, so it is not offered.
# Set ROMM_DOMAIN env var to skip the interactive domain prompt.
#
# RomM — self-hosted ROM manager and in-browser player. Scans a ROM library,
# enriches it from metadata providers (IGDB, ScreenScraper, SteamGridDB,
# RetroAchievements, LaunchBox, Hasheous, ...) and plays games via EmulatorJS.
#
# Upstream: https://github.com/rommapp/romm
# Docs:     https://docs.romm.app/latest/
# Image:    rommapp/romm:latest + mariadb (LTS) in one compose project
#
# What the installer configures (hands-off — no setup wizard):
#   - MariaDB sidecar with generated credentials (secrets live in ${app_dir}/.env, 600)
#   - Every keyless metadata provider enabled (Hasheous, LaunchBox, PlayMatch,
#     Flashpoint, HowLongToBeat, TheGamesDB, Steam)
#   - Keyed providers (IGDB, ScreenScraper, SteamGridDB, RetroAchievements,
#     MobyGames) from ROMM_* env vars or prompts; re-run with --set-providers
#   - config.yml with scan priorities, regions and media types
#   - Library folders (roms/{platform}, bios/{platform}) for a common platform set
#   - Admin account (swizzin master user + its password, like the arrs)
#   - Scheduled rescans, filesystem-change rescans, LaunchBox/Switch DB refresh

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
app_name="romm"
app_pretty="RomM"
app_lockname="${app_name}"
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/romm.png"

app_image="rommapp/romm:latest"
# MariaDB LTS line — pinned to a major so `--update` never jumps majors
db_image="mariadb:11.8"
app_container_port="8080"

app_dir="/opt/romm"
app_envfile="${app_dir}/.env"
app_admin_file="${app_dir}/.admin_credentials"
app_librarydir="${app_dir}/library"
app_assetsdir="${app_dir}/assets"
app_configdir="${app_dir}/config"
app_resourcesdir="${app_dir}/resources"
app_redisdir="${app_dir}/redis-data"
app_dbdir="${app_dir}/mysql"
app_servicefile="${app_name}.service"

# POST/PUT without credentials (setup wizard endpoints). RomM's CSRF middleware
# guards every cookie-less, non-bearer write, so fetch a token cookie first and
# echo it back as x-csrftoken. The cookie is passed by hand because it is
# marked Secure (ROMM_SESSION_SECURE_COOKIE) and curl won't replay it over http.
_csrf_curl() {
    local jar tok
    jar=$(mktemp /tmp/romm-jar-XXXXXX)
    curl -s --max-time 10 -c "$jar" -o /dev/null "${_api}/heartbeat" 2>/dev/null || true
    tok=$(awk '$6 == "romm_csrftoken" {print $7}' "$jar" 2>/dev/null | tail -n1)
    rm -f "$jar"
    curl -sS -H "Cookie: romm_csrftoken=${tok}" -H "x-csrftoken: ${tok}" "$@"
}

# Platform folders created on first install (RomM fs slugs). Override with
# ROMM_PLATFORMS="nes,snes,..." or add more later with --add-platforms.
default_platforms="nes,snes,n64,gb,gbc,gba,nds,3ds,ngc,wii,wiiu,switch,genesis,sms,gamegear,segacd,sega32,saturn,dc,psx,ps2,psp,tg16,neogeoaes,atari2600,arcade"

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
# Domain Resolution (subdomain only — see header)
# ==============================================================================
backup_dir="/opt/swizzin-extras/${app_name}-backups"
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
    echo "${ROMM_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${ROMM_DOMAIN:-}" ]; then
        echo_info "Using domain from ROMM_DOMAIN: $ROMM_DOMAIN"
        app_domain="$ROMM_DOMAIN"
        swizdb set "${app_name}/domain" "$app_domain"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for ${app_pretty}" "[$existing_domain]"
    else
        echo_query "Enter domain for ${app_pretty}" "(e.g., romm.example.com)"
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
    export ROMM_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${ROMM_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from ROMM_LE_INTERACTIVE: $ROMM_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export ROMM_LE_INTERACTIVE="yes"
    else
        export ROMM_LE_INTERACTIVE="no"
    fi
}

_request_certificate() {
    local domain="$1"
    local le_hostname="${ROMM_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${ROMM_LE_INTERACTIVE:-no}"

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
# .env Helpers (secrets + RomM settings; compose reads it via env_file)
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

_gen_secret() {
    openssl rand -hex "${1:-32}"
}

# Generate (once) secrets and seed every installer-managed setting. Existing
# keys are never overwritten, so `bash romm.sh` re-runs and `--update` are safe.
_write_env() {
    local domain="$1"
    local db_pass
    db_pass="$(_env_get DB_PASSWD)"
    [[ -z "$db_pass" ]] && db_pass="$(_gen_secret 24)"

    touch "$app_envfile"
    chmod 600 "$app_envfile"
    chown root:root "$app_envfile"

    # Database (romm + mariadb share this file)
    _env_default DB_HOST "romm-db"
    _env_default DB_PORT "3306"
    _env_default DB_NAME "romm"
    _env_default DB_USER "romm-user"
    _env_default DB_PASSWD "$db_pass"
    _env_default MARIADB_DATABASE "romm"
    _env_default MARIADB_USER "romm-user"
    _env_default MARIADB_PASSWORD "$db_pass"
    _env_default MARIADB_ROOT_PASSWORD "$(_gen_secret 24)"

    # Auth
    _env_default ROMM_AUTH_SECRET_KEY "$(_gen_secret 32)"
    _env_default ROMM_BASE_URL "https://${domain}"
    _env_default ROMM_SESSION_SECURE_COOKIE "true"

    # Keyless metadata providers — all on
    _env_default HASHEOUS_API_ENABLED "true"
    _env_default LAUNCHBOX_API_ENABLED "true"
    _env_default PLAYMATCH_API_ENABLED "true"
    _env_default FLASHPOINT_API_ENABLED "true"
    _env_default HLTB_API_ENABLED "true"
    _env_default TGDB_API_ENABLED "true"
    _env_default STEAM_API_ENABLED "true"

    # Background tasks
    _env_default ENABLE_RESCAN_ON_FILESYSTEM_CHANGE "true"
    _env_default RESCAN_ON_FILESYSTEM_CHANGE_DELAY "5"
    _env_default ENABLE_SCHEDULED_RESCAN "true"
    _env_default SCHEDULED_RESCAN_CRON "0 3 * * *"
    _env_default ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB "true"
    _env_default ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA "true"
    _env_default ENABLE_SCHEDULED_CONVERT_IMAGES_TO_WEBP "true"
    _env_default ENABLE_SCHEDULED_CLEANUP_ORPHANED_RESOURCES "true"

    # Keyed providers from the environment (ROMM_* prefix, empty = skip)
    _apply_provider_env
}

# ==============================================================================
# Metadata Providers (keyed)
# ==============================================================================
# Map: installer env var -> RomM env var
_provider_vars=(
    "ROMM_IGDB_CLIENT_ID:IGDB_CLIENT_ID"
    "ROMM_IGDB_CLIENT_SECRET:IGDB_CLIENT_SECRET"
    "ROMM_SCREENSCRAPER_USER:SCREENSCRAPER_USER"
    "ROMM_SCREENSCRAPER_PASSWORD:SCREENSCRAPER_PASSWORD"
    "ROMM_STEAMGRIDDB_API_KEY:STEAMGRIDDB_API_KEY"
    "ROMM_RETROACHIEVEMENTS_API_KEY:RETROACHIEVEMENTS_API_KEY"
    "ROMM_MOBYGAMES_API_KEY:MOBYGAMES_API_KEY"
)

_apply_provider_env() {
    local pair src dst
    for pair in "${_provider_vars[@]}"; do
        src="${pair%%:*}"
        dst="${pair#*:}"
        if [[ -n "${!src:-}" ]]; then
            _env_set "$dst" "${!src}"
        fi
    done
    # Achievement progress sync only makes sense with an RA key
    if [[ -n "$(_env_get RETROACHIEVEMENTS_API_KEY)" ]]; then
        _env_default ENABLE_SCHEDULED_RETROACHIEVEMENTS_PROGRESS_SYNC "true"
    fi
}

# Prompt for one provider value; Enter keeps the current one. Secrets are read
# silently. Result lands in the ROMM_* variable consumed by _apply_provider_env.
_prompt_provider() {
    local label="$1" src="$2" dst="$3" secret="${4:-false}"
    local current input
    current="$(_env_get "$dst")"
    [[ -n "${!src:-}" ]] && return 0

    if [[ -n "$current" ]]; then
        echo_query "${label}" "[set — Enter to keep]"
    else
        echo_query "${label}" "[Enter to skip]"
    fi
    if [[ "$secret" == "true" ]]; then
        read -rs input </dev/tty || true
        echo ""
    else
        read -r input </dev/tty || true
    fi
    if [[ -n "${input:-}" ]]; then
        printf -v "$src" '%s' "$input"
    fi
}

_prompt_providers() {
    echo_info "Metadata providers (all free except MobyGames):"
    echo_info "  IGDB:              https://dev.twitch.tv/console/apps (Client ID + Secret)"
    echo_info "  ScreenScraper:     https://www.screenscraper.fr (account user/pass)"
    echo_info "  SteamGridDB:       https://www.steamgriddb.com/profile/preferences/api"
    echo_info "  RetroAchievements: https://retroachievements.org/settings (Web API key)"
    _prompt_provider "IGDB Client ID" ROMM_IGDB_CLIENT_ID IGDB_CLIENT_ID
    _prompt_provider "IGDB Client Secret" ROMM_IGDB_CLIENT_SECRET IGDB_CLIENT_SECRET true
    _prompt_provider "ScreenScraper username" ROMM_SCREENSCRAPER_USER SCREENSCRAPER_USER
    _prompt_provider "ScreenScraper password" ROMM_SCREENSCRAPER_PASSWORD SCREENSCRAPER_PASSWORD true
    _prompt_provider "SteamGridDB API key" ROMM_STEAMGRIDDB_API_KEY STEAMGRIDDB_API_KEY true
    _prompt_provider "RetroAchievements API key" ROMM_RETROACHIEVEMENTS_API_KEY RETROACHIEVEMENTS_API_KEY true
    _prompt_provider "MobyGames API key (paid)" ROMM_MOBYGAMES_API_KEY MOBYGAMES_API_KEY true
}

# Interactive prompts only when stdin is a terminal and ROMM_NO_PROMPT isn't set
_can_prompt() {
    [[ -t 0 && -z "${ROMM_NO_PROMPT:-}" ]]
}

# ==============================================================================
# config.yml (scan priorities, regions, media)
# ==============================================================================
_write_config_yml() {
    local cfg="${app_configdir}/config.yml"
    if [[ -f "$cfg" ]]; then
        echo_info "Existing config.yml found, not overwriting"
        return 0
    fi

    cat >"$cfg" <<'YAML'
# RomM configuration — https://docs.romm.app/latest/reference/configuration-file/
# Generated by romm.sh on first install; edit freely (also editable in the UI
# under Library Management). The installer never overwrites this file.

filesystem:
  structure:
    default: "roms/{platform}/{game}"
    firmware: "bios/{platform}"

exclude:
  roms:
    single_file:
      extensions: ["db", "tmp", "bak", "lock", "log", "cache", "crdownload", "assembling", "part", "nfo", "txt", "sfv", "md5"]
    multi_file:
      names: ["downloaded_images", "media", "@eaDir", "#recycle"]

scan:
  priority:
    # Hash-based sources first after IGDB so exact dumps match reliably
    metadata: ["igdb", "ss", "ra", "hasheous", "launchbox", "moby", "tgdb", "flashpoint", "steam", "hltb", "gamelist"]
    artwork: ["sgdb", "igdb", "ss", "launchbox", "moby", "libretro"]
    region: ["us", "wor", "eu", "jp"]
    region_mode: prefer_rom_tags
    language: ["en"]
  media:
    - box2d
    - box3d
    - screenshot
    - title_screen
    - marquee
    - fanart
    - manual
    - bezel
    - physical
    - miximage
    - video

emulatorjs:
  auto_save_sync: true
YAML
    echo_info "Wrote ${cfg}"
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
# Installer-owned artifact — regenerated on install and update. Settings and
# secrets live in .env (env_file), never inline here.
_write_compose() {
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    local cpu_limit="${DOCKER_CPU_LIMIT:-4}"
    local mem_limit="${DOCKER_MEM_LIMIT:-4G}"
    local mem_reserve="${DOCKER_MEM_RESERVE:-512M}"

    # RomM runs as the swizzin user so library/assets stay user-owned (the
    # image's nginx + gunicorn + valkey all run unprivileged on :8080).
    # Healthcheck hits the unauthenticated /api/heartbeat.
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  romm:
    image: ${app_image}
    container_name: romm
    restart: unless-stopped
    user: "${uid}:${gid}"
    env_file: .env
    ports:
      - "127.0.0.1:${app_port}:${app_container_port}"
    volumes:
      - ${app_resourcesdir}:/romm/resources
      - ${app_redisdir}:/redis-data
      - ${app_librarydir}:/romm/library
      - ${app_assetsdir}:/romm/assets
      - ${app_configdir}:/romm/config
    depends_on:
      romm-db:
        condition: service_healthy
        restart: true
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
      test: ["CMD-SHELL", "curl -sf http://127.0.0.1:${app_container_port}/api/heartbeat >/dev/null || exit 1"]
      interval: 1m
      timeout: 10s
      retries: 3
      start_period: 2m

  romm-db:
    image: ${db_image}
    container_name: romm-db
    restart: unless-stopped
    env_file: .env
    volumes:
      - ${app_dbdir}:/var/lib/mysql
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      start_interval: 10s
      interval: 30s
      timeout: 5s
      retries: 5
COMPOSE

    chmod 644 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"
}

# ==============================================================================
# API Helpers
# ==============================================================================
_api="http://127.0.0.1:${app_port}/api"

_wait_for_romm() {
    echo_progress_start "Waiting for ${app_pretty} to come up"
    for _ in $(seq 1 90); do
        if curl -sf --max-time 5 "${_api}/heartbeat" >/dev/null 2>&1; then
            echo_progress_done "${app_pretty} is responding"
            return 0
        fi
        sleep 2
    done
    echo_error "${app_pretty} did not respond within 3 minutes (docker logs romm)"
    exit 1
}

_heartbeat_field() {
    curl -sf --max-time 10 "${_api}/heartbeat" 2>/dev/null | python3 -c "import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split('.'):
    d=d.get(k, {}) if isinstance(d, dict) else {}
print(d if not isinstance(d, dict) else '')" "$1" 2>/dev/null || true
}

# Platform folders via the setup-wizard API (unauthenticated only while no admin
# exists) or, afterwards, with the admin's basic-auth credentials.
_create_platforms() {
    local spec="$1" auth_cfg="${2:-}"
    local body resp
    body=$(python3 -c "import json,sys
print(json.dumps([s.strip() for s in sys.argv[1].split(',') if s.strip()]))" "$spec")

    if [[ -n "$auth_cfg" ]]; then
        resp=$(curl -sS --max-time 60 --config "$auth_cfg" -H "Content-Type: application/json" \
            -d "$body" "${_api}/setup/platforms" 2>>"$log") || true
    else
        resp=$(_csrf_curl --max-time 60 -H "Content-Type: application/json" \
            -d "$body" "${_api}/setup/platforms" 2>>"$log") || true
    fi
    _verbose "setup/platforms: ${resp}"
    if printf '%s' "$resp" | grep -q '"success": *true'; then
        echo_info "Platform folders: $(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || true)"
    else
        echo_warn "Could not create platform folders: ${resp:-no response}"
    fi
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

# Create the admin (swizzin master user + master password, else generated)
# when none exists.
_create_admin() {
    local show_wizard
    show_wizard="$(_heartbeat_field SYSTEM.SHOW_SETUP_WIZARD)"
    if [[ "$show_wizard" != "True" ]]; then
        echo_info "Admin account already exists — skipping"
        return 0
    fi

    local admin_user="${ROMM_ADMIN_USER:-$user}"
    local admin_pass="${ROMM_ADMIN_PASSWORD:-}"
    [[ -z "$admin_pass" && "$admin_user" == "$user" ]] && admin_pass="$(_master_password)"
    [[ -n "$admin_pass" ]] || admin_pass="$(_gen_secret 12)"
    local body_file resp
    body_file=$(mktemp /tmp/romm-admin-XXXXXX.json)
    chmod 600 "$body_file"
    python3 -c "import json,sys
print(json.dumps({'username': sys.argv[1], 'password': sys.argv[2], 'email': '', 'role': 'admin'}))" \
        "$admin_user" "$admin_pass" >"$body_file"
    resp=$(_csrf_curl --max-time 30 -H "Content-Type: application/json" \
        -d @"$body_file" "${_api}/users" 2>>"$log") || true
    rm -f "$body_file"

    if printf '%s' "$resp" | grep -q '"username"'; then
        umask 077
        printf 'username=%s\npassword=%s\n' "$admin_user" "$admin_pass" >"$app_admin_file"
        chmod 600 "$app_admin_file"
        chown root:root "$app_admin_file"
        echo_info "Admin account '${admin_user}' created (credentials in ${app_admin_file})"
    else
        echo_warn "Admin creation failed: ${resp:-no response} — finish setup in the web UI"
    fi
}

# Basic-auth curl config for the stored admin (600, keeps password out of ps)
_admin_auth_cfg() {
    [[ -f "$app_admin_file" ]] || return 1
    local u p cfg
    u=$(grep '^username=' "$app_admin_file" | cut -d= -f2-)
    p=$(grep '^password=' "$app_admin_file" | cut -d= -f2-)
    cfg=$(mktemp /tmp/romm-auth-XXXXXX.conf)
    chmod 600 "$cfg"
    printf 'user = "%s:%s"\n' "$u" "$p" >"$cfg"
    echo "$cfg"
}

_show_providers() {
    curl -sf --max-time 10 "${_api}/heartbeat" 2>/dev/null | python3 -c "import json,sys
m=json.load(sys.stdin).get('METADATA_SOURCES',{})
on=[k.replace('_API_ENABLED','') for k,v in m.items() if k.endswith('_API_ENABLED') and v]
off=[k.replace('_API_ENABLED','') for k,v in m.items() if k.endswith('_API_ENABLED') and not v]
print('  enabled:  ' + ', '.join(sorted(on)))
print('  disabled: ' + (', '.join(sorted(off)) or '-'))" 2>/dev/null || echo_warn "Could not read provider status"
}

# ==============================================================================
# App Installation
# ==============================================================================
_install_romm() {
    local domain="$1"

    mkdir -p "$app_dir" "$app_librarydir/roms" "$app_librarydir/bios" \
        "$app_assetsdir" "$app_configdir" "$app_resourcesdir" "$app_redisdir" "$app_dbdir"
    chown "${user}:${user}" "$app_librarydir" "$app_librarydir/roms" "$app_librarydir/bios" \
        "$app_assetsdir" "$app_configdir" "$app_resourcesdir" "$app_redisdir"

    swizdb set "${app_name}/port" "$app_port"

    if _can_prompt; then
        _prompt_providers
    fi
    _write_env "$domain"
    _write_config_yml
    chown "${user}:${user}" "${app_configdir}/config.yml"

    echo_progress_start "Generating Docker Compose configuration"
    _write_compose
    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling ${app_pretty} Docker images"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker images"
        exit 1
    }
    echo_progress_done "Docker images pulled"

    echo_progress_start "Starting ${app_pretty} containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "${app_pretty} containers started"

    _wait_for_romm

    # Platform folders must be created while the setup API is still open
    # (before the admin exists)
    local platforms="${ROMM_PLATFORMS:-$default_platforms}"
    if [[ "$(_heartbeat_field SYSTEM.SHOW_SETUP_WIZARD)" == "True" ]]; then
        _create_platforms "$platforms"
    fi
    _create_admin
    _prime_metadata_stores
}

# LaunchBox and Switch TitleDB are local stores the scanner reads; their
# scheduled refresh is nightly, so a fresh install would scan against empty
# stores until then. Kick both once (background jobs, return immediately).
_prime_metadata_stores() {
    local auth_cfg t
    auth_cfg=$(_admin_auth_cfg) || return 0
    for t in update_launchbox_metadata update_switch_titledb; do
        curl -sf --max-time 30 --config "$auth_cfg" -X POST "${_api}/tasks/run/${t}" >/dev/null 2>&1 \
            && _verbose "Started ${t}" || echo_warn "Could not start ${t} (runs nightly anyway)"
    done
    rm -f "$auth_cfg"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_romm() {
    echo_progress_start "Installing systemd service"

    local mem_max="${SYSTEMD_MEM_MAX:-5G}"
    local cpu_quota="${SYSTEMD_CPU_QUOTA:-400%}"
    local tasks_max="${SYSTEMD_TASKS_MAX:-4096}"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (ROM manager)
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
TimeoutStartSec=180
TimeoutStopSec=60

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

    # ssl-params.conf may advertise HTTP/3 (Alt-Svc). Clients that honour it
    # (iOS URLSession) then switch to QUIC, so this vhost must listen on QUIC
    # too, or the handshake lands on another server's certificate.
    local quic_listen=""
    if grep -qs 'Alt-Svc' /etc/nginx/snippets/ssl-params.conf; then
        quic_listen=$'    listen 443 quic;\n    listen [::]:443 quic;\n    http3 on;'
    fi

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

    # RomM's own in-container nginx already sets COEP/COOP for the EmulatorJS
    # player and the cache headers; this vhost only terminates TLS. Uploads
    # (ROMs, saves) can be large, and downloads stream from disk — no buffering.
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
${quic_listen}
    server_name $domain;

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    include snippets/ssl-params.conf;

    client_max_body_size 0;
    proxy_redirect off;
    proxy_buffering off;
    proxy_request_buffering off;

    proxy_read_timeout 600;
    proxy_send_timeout 600;
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

        # socket.io (/ws scan progress, /netplay)
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
    local le_hostname="${ROMM_LE_HOSTNAME:-$domain}"
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
            _install_romm "$domain"
            _systemd_romm
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
    echo_info "Metadata providers:"
    _show_providers
    echo_info "  Add/change keys any time: bash $0 --set-providers"
    echo ""
    echo_info "Library:  ${app_librarydir}/roms/<platform>/  (BIOS: ${app_librarydir}/bios/<platform>/)"
    echo_info "  Drop ROMs in and RomM rescans automatically (filesystem watcher + nightly 03:00)."
    echo_info "  More platform folders: bash $0 --add-platforms psvita,xbox,..."
    echo ""
    echo_info "Logs:     docker logs -f romm"
    echo_info "Settings: ${app_envfile} (secrets, 600) and ${app_configdir}/config.yml"
    echo ""
}

# ==============================================================================
# Recreate containers after .env changes
# ==============================================================================
_recreate() {
    echo_progress_start "Recreating ${app_pretty} containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d --force-recreate romm >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"
    _wait_for_romm
}

# ==============================================================================
# --set-providers
# ==============================================================================
_set_providers() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    if _can_prompt; then
        _prompt_providers
    fi
    _apply_provider_env
    _recreate
    echo_info "Metadata providers:"
    _show_providers
    echo_success "Provider configuration applied"
    exit 0
}

# ==============================================================================
# --add-platforms
# ==============================================================================
_add_platforms() {
    local spec="${1:-}"
    if [[ -z "$spec" ]]; then
        echo_error "Usage: $0 --add-platforms <slug>[,<slug>...]  (slugs: https://docs.romm.app/latest/platforms-and-players/supported-platforms/)"
        exit 1
    fi
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    local auth_cfg
    auth_cfg=$(_admin_auth_cfg) || {
        echo_error "No stored admin credentials (${app_admin_file}); create folders manually under ${app_librarydir}/roms/"
        exit 1
    }
    _create_platforms "$spec" "$auth_cfg"
    rm -f "$auth_cfg"
    exit 0
}

# ==============================================================================
# Update
# ==============================================================================
_update_romm() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    # Regenerate compose (installer-owned); .env and config.yml are preserved,
    # but new installer-managed defaults are seeded if missing.
    _write_env "$(_get_domain)"
    _write_compose

    echo_progress_start "Pulling latest ${app_pretty} images"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest images"
        exit 1
    }
    echo_progress_done "Latest images pulled"

    echo_progress_start "Recreating ${app_pretty} containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"

    _wait_for_romm

    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_romm() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig
    if ask "Purge configuration, database and assets? (the ROM library at ${app_librarydir} is kept unless you confirm separately)" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    echo_progress_start "Stopping ${app_pretty} containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

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

    _include_in_organizr

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration, database and assets"
        rm -rf "$app_dbdir" "$app_assetsdir" "$app_configdir" "$app_resourcesdir" "$app_redisdir" \
            "$app_envfile" "$app_admin_file" "${app_dir}/docker-compose.yml"
        echo_progress_done "Configuration purged"
        if ask "Also delete the ROM library at ${app_librarydir}?" N; then
            rm -rf "$app_dir"
        else
            echo_info "ROM library kept at: ${app_librarydir}"
        fi
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        swizdb clear "${app_name}/domain" 2>/dev/null || true
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
    echo "  --update                  Pull images and recreate containers"
    echo "  --remove [--force]        Complete removal (prompts to purge config / library)"
    echo "  --register-panel          Re-register with swizzin panel"
    echo "  --set-providers           Set/replace metadata provider keys (prompts, or ROMM_* env vars)"
    echo "  --add-platforms <slugs>   Create platform folders (comma-separated RomM slugs)"
    echo "  --status                  Show provider status"
    echo ""
    echo "Environment variable overrides:"
    echo "  ROMM_DOMAIN                     Subdomain for RomM (e.g. romm.example.com)"
    echo "  ROMM_LE_INTERACTIVE             yes|no — interactive Let's Encrypt mode (default: no)"
    echo "  ROMM_LE_HOSTNAME                Request cert for a different hostname (e.g. wildcard)"
    echo "  ROMM_PLATFORMS                  Platform folders to create on install (comma-separated)"
    echo "  ROMM_ADMIN_USER / _PASSWORD     Admin account (default: master user + its swizzin password)"
    echo "  ROMM_NO_PROMPT                  Non-empty — never prompt for provider keys"
    echo "  ROMM_IGDB_CLIENT_ID / _SECRET   IGDB (Twitch) credentials"
    echo "  ROMM_SCREENSCRAPER_USER / _PASSWORD"
    echo "  ROMM_STEAMGRIDDB_API_KEY"
    echo "  ROMM_RETROACHIEVEMENTS_API_KEY"
    echo "  ROMM_MOBYGAMES_API_KEY"
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
        _update_romm
        ;;
    "--remove")
        _remove_romm "${2:-}"
        ;;
    "--set-providers")
        _set_providers
        ;;
    "--add-platforms")
        _add_platforms "${2:-}"
        ;;
    "--status")
        echo_info "Metadata providers:"
        _show_providers
        exit 0
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        app_domain="$(_get_domain)"
        if [[ -z "$app_domain" ]]; then
            echo_error "No domain stored in swizdb for ${app_name}. Run the installer first or set ROMM_DOMAIN."
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
