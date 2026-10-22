#!/bin/bash
set -euo pipefail
# romarr installer
# STiXzoOR 2026
# Usage: bash romarr.sh [--update [--verbose]|--remove [--force]|--register-panel|--wire|--status]
#
# Subdomain-only — ROMarr's UI hardcodes ~110 '/api/...' paths at the web root
# and its stdlib http.server has no URL base. Set ROMARR_DOMAIN to skip the
# interactive domain prompt.
#
# ROMarr — *arr-style automation for ROMs: searches Prowlarr, hands releases to
# a download client, verifies against No-Intro/Redump DATs, files the result
# into the game library (RomM's roms/{fs_slug}) and asks RomM to scan.
#
# Upstream: https://github.com/BlizzHacker/romarr  (MIT)
# Image:    ghcr.io/blizzhacker/romarr (pinned; override with ROMARR_VERSION)
#
# What the installer wires (auto-discovered, every step optional):
#   - Prowlarr          (indexers)              — swizzin prowlarr config.xml
#   - nzbdav            (usenet, SABnzbd API)   — adds a 'romarr' category live
#   - Real-Debrid       (torrent, direct)       — ROMARR_RD_API_TOKEN, else the
#                                                  key decypharr already uses
#   - decypharr         (torrent, qBittorrent)  — standby client after RD
#   - RomM              (library + scan)        — dedicated 'romarr' RomM user
# ROMarr routes each grab to the FIRST enabled client for its protocol (no
# failover), so torrent order is RD direct (fetches uncached torrents) then
# decypharr (cached-only). The site-scraping 'direct'/'browser' downloaders and
# ROM Hub plugins are never configured.
#
# Networking: host network — Prowlarr binds 127.0.0.1 only, so a bridged
# container could not reach it. ROMarr binds 0.0.0.0:<port> (no bind option
# upstream); keep that port closed in the firewall (ufw default-deny does).


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
app_name="romarr"
app_pretty="ROMarr"
app_lockname="${app_name}"
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/romarr.png"

app_version="${ROMARR_VERSION:-1.6.0}"
app_image="ghcr.io/blizzhacker/romarr:${app_version}"

app_dir="/opt/romarr"
app_envfile="${app_dir}/.env"
app_configdir="${app_dir}/config"
app_stagingdir="${app_dir}/downloads"
app_servicefile="${app_name}.service"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"

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
    echo "${ROMARR_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${ROMARR_DOMAIN:-}" ]; then
        echo_info "Using domain from ROMARR_DOMAIN: $ROMARR_DOMAIN"
        app_domain="$ROMARR_DOMAIN"
        swizdb set "${app_name}/domain" "$app_domain"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for ${app_pretty}" "[$existing_domain]"
    else
        echo_query "Enter domain for ${app_pretty}" "(e.g., romarr.example.com)"
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
    export ROMARR_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${ROMARR_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from ROMARR_LE_INTERACTIVE: $ROMARR_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export ROMARR_LE_INTERACTIVE="yes"
    else
        export ROMARR_LE_INTERACTIVE="no"
    fi
}

_request_certificate() {
    local domain="$1"
    local le_hostname="${ROMARR_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${ROMARR_LE_INTERACTIVE:-no}"

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
# .env Helpers (compose reads it via env_file)
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


# ==============================================================================
# Integration Discovery
# ==============================================================================
# Each _discover_* prints nothing (and returns 0) when the app isn't installed,
# so every integration is optional.

# Prowlarr: "<url> <apikey>" from the owner's config.xml
_discover_prowlarr() {
    local cfg="/home/${user}/.config/Prowlarr/config.xml"
    [[ -f /install/.prowlarr.lock && -f "$cfg" ]] || return 0
    local port base key
    port=$(grep -oP '(?<=<Port>)[^<]+' "$cfg" | head -1)
    base=$(grep -oP '(?<=<UrlBase>)[^<]*' "$cfg" | head -1)
    key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" | head -1)
    [[ -n "$port" && -n "$key" ]] || return 0
    echo "http://127.0.0.1:${port}${base:+/${base#/}} ${key}"
}

# nzbdav: "<url> <apikey>" (SABnzbd-compatible API)
_discover_nzbdav() {
    local db="/opt/nzbdav/config/db.sqlite" port key
    [[ -f /install/.nzbdav.lock && -f "$db" ]] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    port=$(swizdb get "nzbdav/port" 2>/dev/null) || true
    key=$(sqlite3 -readonly "$db" "SELECT ConfigValue FROM ConfigItems WHERE ConfigName='api.key'" 2>/dev/null) || true
    [[ -n "$port" && -n "$key" ]] || return 0
    echo "http://127.0.0.1:${port}/nzbdav ${key}"
}

# decypharr: "<port> <url_base>" (qBittorrent-compatible API)
_discover_decypharr() {
    local cfg="/home/${user}/.config/Decypharr/config.json"
    [[ -f /install/.decypharr.lock && -f "$cfg" ]] || return 0
    python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('port') or '', (d.get('url_base') or '/').rstrip('/') or '/')" "$cfg" 2>/dev/null || true
}

# Real-Debrid API token: ROMARR_RD_API_TOKEN, else the one decypharr uses
_discover_rd_token() {
    if [[ -n "${ROMARR_RD_API_TOKEN:-}" ]]; then
        echo "$ROMARR_RD_API_TOKEN"
        return 0
    fi
    local cfg="/home/${user}/.config/Decypharr/config.json"
    [[ -f "$cfg" ]] || return 0
    python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get('debrids') or []:
    if (x.get('provider') or x.get('name')) == 'realdebrid' and x.get('api_key'):
        print(x['api_key']); break" "$cfg" 2>/dev/null || true
}

# RomM: "<url> <roms_path>" (from romm.sh install)
_discover_romm() {
    [[ -f /install/.romm.lock ]] || return 0
    local port
    port=$(swizdb get "romm/port" 2>/dev/null) || true
    [[ -n "$port" ]] || return 0
    echo "http://127.0.0.1:${port} /opt/romm/library/roms"
}

# ==============================================================================
# Integration Setup (side effects in other apps)
# ==============================================================================

# Add the 'romarr' category to nzbdav (live config API, no restart) and to its
# article-existence check list, keeping every existing category.
_nzbdav_add_category() {
    local url="$1" key="$2" db="/opt/nzbdav/config/db.sqlite"
    local cats ensure new_cats new_ensure
    cats=$(sqlite3 -readonly "$db" "SELECT ConfigValue FROM ConfigItems WHERE ConfigName='api.categories'" 2>/dev/null) || true
    ensure=$(sqlite3 -readonly "$db" "SELECT ConfigValue FROM ConfigItems WHERE ConfigName='api.ensure-article-existence-categories'" 2>/dev/null) || true
    new_cats=$(_list_add "$cats" "$app_name")
    new_ensure=$(_list_add "$ensure" "$app_name")
    if [[ "$new_cats" == "$cats" && "$new_ensure" == "$ensure" ]]; then
        _verbose "nzbdav already has the ${app_name} category"
        return 0
    fi
    if curl -sf --max-time 20 -X POST "${url}/api/update-config?apikey=${key}" \
        --data-urlencode "api.categories=${new_cats}" \
        --data-urlencode "api.ensure-article-existence-categories=${new_ensure}" 2>>"$log" | grep -q '"status":true'; then
        echo_info "Added '${app_name}' category to nzbdav"
    else
        echo_warn "Could not add '${app_name}' category to nzbdav (downloads still work, uncategorised)"
    fi
}

# Remove the category again on --remove
_nzbdav_remove_category() {
    local disc url key db="/opt/nzbdav/config/db.sqlite" cats ensure
    disc=$(_discover_nzbdav)
    [[ -n "$disc" ]] || return 0
    read -r url key <<<"$disc"
    cats=$(sqlite3 -readonly "$db" "SELECT ConfigValue FROM ConfigItems WHERE ConfigName='api.categories'" 2>/dev/null) || true
    ensure=$(sqlite3 -readonly "$db" "SELECT ConfigValue FROM ConfigItems WHERE ConfigName='api.ensure-article-existence-categories'" 2>/dev/null) || true
    curl -sf --max-time 20 -X POST "${url}/api/update-config?apikey=${key}" \
        --data-urlencode "api.categories=$(_list_del "$cats" "$app_name")" \
        --data-urlencode "api.ensure-article-existence-categories=$(_list_del "$ensure" "$app_name")" >/dev/null 2>&1 || true
}

# Comma-separated list helpers ("a, b, c")
_list_add() {
    python3 -c "import sys
items=[x.strip() for x in sys.argv[1].split(',') if x.strip()]
if sys.argv[2] not in items: items.append(sys.argv[2])
print(', '.join(items))" "${1:-}" "$2"
}
_list_del() {
    python3 -c "import sys
print(', '.join(x.strip() for x in sys.argv[1].split(',') if x.strip() and x.strip()!=sys.argv[2]))" "${1:-}" "$2"
}

# Dedicated RomM account for ROMarr. RomM 5.x has only user/admin roles (the
# old editor/viewer split moved into permission groups) and triggering a scan
# needs tasks.run, so the account is an admin. Credentials: 600, root.
_ensure_romm_user() {
    local romm_url="$1"
    local cred="/opt/romm/.romarr_credentials" admin="/opt/romm/.admin_credentials"
    if [[ -f "$cred" ]]; then
        return 0
    fi
    if [[ ! -f "$admin" ]]; then
        echo_warn "No RomM admin credentials at ${admin}; create ${cred} (username=/password= lines) by hand"
        return 1
    fi
    local au ap pass cfg body resp uid
    au=$(grep '^username=' "$admin" | cut -d= -f2-)
    ap=$(grep '^password=' "$admin" | cut -d= -f2-)
    pass=$(_gen_secret 12)
    cfg=$(mktemp /tmp/romarr-romm-XXXXXX.conf)
    chmod 600 "$cfg"
    printf 'user = "%s:%s"\n' "$au" "$ap" >"$cfg"

    body=$(python3 -c "import json,sys
print(json.dumps({'username':'romarr','password':sys.argv[1],'email':'','role':'admin'}))" "$pass")
    resp=$(curl -sS --max-time 30 --config "$cfg" -H "Content-Type: application/json" \
        -d "$body" "${romm_url}/api/users" 2>>"$log") || true
    if ! printf '%s' "$resp" | grep -q '"username"'; then
        # Already exists (e.g. created by hand): reset its password instead
        uid=$(curl -sS --max-time 20 --config "$cfg" "${romm_url}/api/users" 2>/dev/null | python3 -c "import json,sys
print(next((u['id'] for u in json.load(sys.stdin) if u['username']=='romarr'),''))" 2>/dev/null) || true
        if [[ -z "$uid" ]] || ! curl -sf --max-time 20 --config "$cfg" -X PUT \
            -F "password=${pass}" -F role=admin "${romm_url}/api/users/${uid}" >/dev/null 2>&1; then
            rm -f "$cfg"
            echo_warn "Could not create the RomM 'romarr' user: ${resp:-no response}"
            return 1
        fi
    fi
    rm -f "$cfg"
    umask 077
    printf 'username=romarr\npassword=%s\n' "$pass" >"$cred"
    chmod 600 "$cred"
    echo_info "RomM user 'romarr' ready (credentials in ${cred})"
}

# Never-expiring RomM client token (rmm_...) for the romarr account. ROMarr
# re-authenticates only on 401, but RomM 5.x answers an expired OAuth bearer
# with a 500 (unhandled OAuthCredentialsException), so password auth breaks
# ~30 min after every start. A static client token sidesteps the OAuth flow.
_ensure_romm_token() {
    local romm_url="$1" cred="/opt/romm/.romarr_credentials"
    [[ -f "$cred" ]] || return 1
    if grep -q '^token=rmm_' "$cred"; then
        return 0
    fi
    local u p cfg tok tmp
    u=$(grep '^username=' "$cred" | cut -d= -f2-)
    p=$(grep '^password=' "$cred" | cut -d= -f2-)
    cfg=$(mktemp /tmp/romarr-romm-XXXXXX.conf)
    chmod 600 "$cfg"
    printf 'user = "%s:%s"\n' "$u" "$p" >"$cfg"
    tok=$(curl -sS --max-time 30 --config "$cfg" -H "Content-Type: application/json" \
        -d '{"name":"romarr","scopes":["me.read","roms.read","platforms.read","collections.read","tasks.run"],"expires_in":"never"}' \
        "${romm_url}/api/client-tokens" 2>>"$log" | python3 -c "import json,sys
d=json.load(sys.stdin); print(d.get('raw_token') or '')" 2>/dev/null) || true
    rm -f "$cfg"
    if [[ "$tok" != rmm_* ]]; then
        echo_warn "Could not create a RomM client token — ROMarr will lose RomM access when its OAuth token expires"
        return 1
    fi
    tmp=$(mktemp "${cred}.XXXXXX")
    grep -v '^token=' "$cred" >"$tmp" || true
    echo "token=${tok}" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$cred"
    echo_info "RomM client token created for ROMarr (non-expiring)"
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

# ==============================================================================
# .env (first-run settings; ROMarr only reads client/indexer/library env vars
# on its first start, later changes go through the API — see _wire)
# ==============================================================================
_write_env() {
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    touch "$app_envfile"
    chmod 600 "$app_envfile"
    chown root:root "$app_envfile"

    _env_default PUID "$uid"
    _env_default PGID "$gid"
    _env_default UMASK "002"
    _env_default TZ "$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)"
    _env_default ROMARR_PORT "$app_port"
    # Same login as the arrs when the owner is the swizzin master user
    local pw
    pw="$(_master_password)"
    _env_default ROMARR_PASSWORD "${pw:-$(_gen_secret 12)}"
    _env_default ROMARR_API_KEY "$(_gen_secret 16)"
    _env_default LOG_LEVEL "INFO"

    local disc url key
    disc=$(_discover_prowlarr)
    if [[ -n "$disc" ]]; then
        read -r url key <<<"$disc"
        _env_default PROWLARR_URL "$url"
        _env_default PROWLARR_API_KEY "$key"
    else
        echo_warn "Prowlarr not found — add an indexer in the ROMarr UI"
    fi

    disc=$(_discover_nzbdav)
    if [[ -n "$disc" ]]; then
        read -r url key <<<"$disc"
        _env_default SABNZBD_URL "$url"
        _env_default SABNZBD_API_KEY "$key"
        _env_default SABNZBD_CATEGORY "$app_name"
        _nzbdav_add_category "$url" "$key"
    fi

    disc=$(_discover_romm)
    if [[ -n "$disc" ]]; then
        local romm_url roms
        read -r romm_url roms <<<"$disc"
        if _ensure_romm_user "$romm_url"; then
            _env_default LIBRARY_KIND "romm"
            _env_default LIBRARY_URL "$romm_url"
            _env_default LIBRARY_USERNAME "$(grep '^username=' /opt/romm/.romarr_credentials | cut -d= -f2-)"
            _env_default LIBRARY_PASSWORD "$(grep '^password=' /opt/romm/.romarr_credentials | cut -d= -f2-)"
            _env_default LIBRARY_PATH "$roms"
            if _ensure_romm_token "$romm_url"; then
                _env_default LIBRARY_API_KEY "$(grep '^token=' /opt/romm/.romarr_credentials | cut -d= -f2-)"
            fi
        fi
    else
        _env_default LIBRARY_KIND "folder"
        _env_default LIBRARY_PATH "${ROMARR_LIBRARY_PATH:-/home/${user}/roms}"
        echo_warn "RomM not installed — filing ROMs into $(_env_get LIBRARY_PATH) (folder library)"
    fi
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
_write_compose() {
    local library
    library="$(_env_get LIBRARY_PATH)"
    mkdir -p "$library"

    # Library is mounted at the SAME path inside so the paths ROMarr records
    # match the host (and RomM's view). /mnt is read-only + rslave so download
    # client paths (nzbdav completed-symlinks, decypharr symlinks into the
    # zurg mount) resolve for the copy-on-import.
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  romarr:
    image: ${app_image}
    container_name: romarr
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - ${app_configdir}:/config
      - ${app_stagingdir}:/downloads
      - ${library}:${library}
      - /mnt:/mnt:ro,rslave
    deploy:
      resources:
        limits:
          cpus: '${DOCKER_CPU_LIMIT:-2}'
          memory: ${DOCKER_MEM_LIMIT:-2G}
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request,os;urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('ROMARR_PORT','6868')+'/api/health',timeout=5)\""]
      interval: 1m
      timeout: 10s
      retries: 3
      start_period: 30s
COMPOSE
    chmod 644 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"
}

# ==============================================================================
# ROMarr API
# ==============================================================================
_api() {
    local method="$1" path="$2" body="${3:-}"
    local cfg rc=0
    # API key in a 600-perm curl config so it stays out of `ps`
    cfg=$(mktemp /tmp/romarr-api-XXXXXX.conf)
    chmod 600 "$cfg"
    printf 'header = "X-Api-Key: %s"\n' "$(_env_get ROMARR_API_KEY)" >"$cfg"
    if [[ -n "$body" ]]; then
        printf '%s' "$body" | curl -sS --max-time 60 -X "$method" --config "$cfg" \
            -H "Content-Type: application/json" --data-binary @- \
            "http://127.0.0.1:${app_port}${path}" || rc=$?
    else
        curl -sS --max-time 60 -X "$method" --config "$cfg" \
            "http://127.0.0.1:${app_port}${path}" || rc=$?
    fi
    rm -f "$cfg"
    return "$rc"
}

_wait_for_romarr() {
    echo_progress_start "Waiting for ${app_pretty} to come up"
    for _ in $(seq 1 60); do
        if curl -sf --max-time 5 "http://127.0.0.1:${app_port}/api/health" >/dev/null 2>&1; then
            echo_progress_done "${app_pretty} is responding"
            return 0
        fi
        sleep 2
    done
    echo_error "${app_pretty} did not respond within 2 minutes (docker logs romarr)"
    exit 1
}

# Names of configured download clients, one per line
_client_names() {
    _api GET /api/v1/downloadclient | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('items',[])
print('\n'.join(c.get('name','') for c in d))" 2>/dev/null || true
}

# Upsert a download client by name (POST is an upsert keyed on name/id)
_add_client() {
    local name="$1" body="$2" resp
    if _client_names | grep -qxF "$name"; then
        _verbose "Download client '${name}' already configured"
        return 0
    fi
    resp=$(_api POST /api/v1/downloadclient "$body" 2>>"$log") || true
    if printf '%s' "$resp" | grep -q '"id"'; then
        echo_info "Added download client: ${name}"
    else
        echo_warn "Could not add download client '${name}': ${resp:-no response}"
    fi
}

# Torrent clients — added after first start (ROMarr's env only seeds one
# qBittorrent). Order matters: the first enabled torrent client takes every
# torrent grab.
# Put the RomM client token on ROMarr's RomM library entry (env vars are only
# read on ROMarr's first start, so existing installs need the API upsert), then
# restart so the live client drops its cached OAuth token.
_wire_romm_token() {
    local disc romm_url roms tok lib
    disc=$(_discover_romm)
    [[ -n "$disc" ]] || return 0
    read -r romm_url roms <<<"$disc"
    _ensure_romm_token "$romm_url" || return 0
    tok=$(grep '^token=' /opt/romm/.romarr_credentials | cut -d= -f2-)
    lib=$(_api GET /api/v1/library | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('items',[])
r=next((x for x in d if x.get('type')=='romm'),None)
print(json.dumps(r) if r else '')" 2>/dev/null) || true
    [[ -n "$lib" ]] || return 0
    if printf '%s' "$lib" | grep -q '"readable": true'; then
        _verbose "ROMarr already reads RomM"
        return 0
    fi
    _api POST /api/v1/library "$(python3 -c "import json,sys
l=json.loads(sys.argv[1])
print(json.dumps({'id':l['id'],'type':'romm','name':l.get('name') or 'RomM','enable':True,
                  'url':l.get('url'),'path':l.get('path'),'is_default':bool(l.get('is_default')),
                  'api_key':sys.argv[2]}))" "$lib" "$tok")" >/dev/null 2>>"$log" || true
    docker restart romarr >>"$log" 2>&1 || true
    _wait_for_romarr
    echo_info "ROMarr now authenticates to RomM with a client token"
}

_wire() {
    _wire_romm_token
    _install_recover_cron
    local rd decy port base
    rd=$(_discover_rd_token)
    if [[ -n "$rd" ]]; then
        mkdir -p "${app_stagingdir}/realdebrid"
        chown -R "${user}:${user}" "$app_stagingdir"
        _add_client "Real-Debrid" "$(python3 -c "import json,sys
print(json.dumps({'type':'realdebrid','name':'Real-Debrid','enable':True,
                  'api_token':sys.argv[1],'save_path':'/downloads/realdebrid'}))" "$rd")"
    fi

    decy=$(_discover_decypharr)
    if [[ -n "$decy" ]]; then
        read -r port base <<<"$decy"
        # decypharr authenticates qBit clients as "arrs": username = the
        # client's own URL, password = its API key (it registers an arr entry)
        _add_client "Decypharr" "$(python3 -c "import json,sys
print(json.dumps({'type':'qbittorrent','name':'Decypharr','enable':True,
                  'host':'127.0.0.1','port':int(sys.argv[1]),'use_ssl':False,
                  'url_base':sys.argv[2] if sys.argv[2] != '/' else '',
                  'username':'http://127.0.0.1:'+sys.argv[3],'password':sys.argv[4],
                  'category':'romarr'}))" "$port" "$base" "$app_port" "$(_env_get ROMARR_API_KEY)")"
        if ! grep -q '"nsp"' "/home/${user}/.config/Decypharr/config.json" 2>/dev/null; then
            echo_warn "decypharr's allowed_file_types has no ROM extensions — ROM torrents through it"
            echo_warn "will import nothing. Real-Debrid direct (first client) is unaffected."
        fi
    fi
}

# ==============================================================================
# Stalled-import recovery (--recover-stalled, run by cron every 5 minutes)
# ==============================================================================
# ROMarr v1.0.0 matches finished downloads to its queue by NAME
# (item.release == the client's torrent name). When the indexer title differs
# from the torrent's internal name the item sits at "grabbed" forever. Every
# queue item does carry the torrent hash (release_id "btih:<hash>"), so match
# by hash instead: find the finished payload in Real-Debrid's staging area or
# decypharr, Manual Import it with the queued platform, and drop the item.
_recover_stalled() {
    [[ -f "/install/.${app_lockname}.lock" ]] || exit 0
    local decy dport dbase cfg
    decy=$(_discover_decypharr)
    read -r dport dbase <<<"${decy:-}"
    cfg=$(mktemp /tmp/romarr-recover-XXXXXX.json)
    chmod 600 "$cfg"
    python3 -c "import json,sys
print(json.dumps({'romarr':'http://127.0.0.1:'+sys.argv[1],'romarr_key':sys.argv[2],
  'rd_token':sys.argv[3],'staging':sys.argv[4],
  'qbit':('http://127.0.0.1:'+sys.argv[5]+(sys.argv[6] if sys.argv[6]!='/' else '')) if sys.argv[5] else '',
  'min_age':int(sys.argv[7])}))" \
        "$app_port" "$(_env_get ROMARR_API_KEY)" "$(_discover_rd_token)" "$app_stagingdir" \
        "${dport:-}" "${dbase:-/}" "${ROMARR_STALL_MINUTES:-10}" >"$cfg"
    python3 - "$cfg" <<'PYREC'
import json, os, sys, time, urllib.parse, urllib.request
from datetime import datetime, timezone

cfg = json.load(open(sys.argv[1]))
os.unlink(sys.argv[1])

def call(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read()
        return r.headers, (json.loads(body) if body[:1] in (b"{", b"[") else body)

R = cfg["romarr"]; RH = {"X-Api-Key": cfg["romarr_key"]}
def romarr(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    h = dict(RH, **({"Content-Type": "application/json"} if data else {}))
    return call(R + path, data, h, "POST" if data else "GET")[1]

queue = romarr("/api/v1/queue").get("items", [])
now = datetime.now(timezone.utc)
stalled = []
for it in queue:
    rid = (it.get("release_id") or "").lower()
    if it.get("state") != "grabbed" or not rid.startswith("btih:"):
        continue
    age = (now - datetime.fromisoformat(it["at"])).total_seconds() / 60
    if age >= cfg["min_age"]:
        stalled.append(it)
if not stalled:
    sys.exit(0)

rd = {}
if cfg["rd_token"]:
    try:
        _, ts = call("https://api.real-debrid.com/rest/1.0/torrents?limit=200",
                     headers={"Authorization": "Bearer " + cfg["rd_token"]})
        rd = {t["hash"].lower(): t for t in ts if t.get("status") == "downloaded"}
    except Exception as e:
        print("RD lookup failed:", e)

qcookie = None
def qbit_path(h):
    global qcookie
    if not cfg["qbit"]:
        return None
    try:
        if qcookie is None:
            hdrs, _ = call(cfg["qbit"] + "/api/v2/auth/login", urllib.parse.urlencode(
                {"username": R, "password": cfg["romarr_key"]}).encode())
            qcookie = (hdrs.get("Set-Cookie") or "").split(";")[0]
        _, ts = call(cfg["qbit"] + "/api/v2/torrents/info?hashes=" + h, headers={"Cookie": qcookie})
        for t in ts or []:
            if t.get("progress", 0) >= 1 and t.get("content_path"):
                return t["content_path"]
    except Exception as e:
        print("decypharr lookup failed:", e)
    return None

def payload_files(host_path, container_path):
    if os.path.isdir(host_path):
        return [os.path.join(container_path, f) for f in sorted(os.listdir(host_path))
                if not f.startswith(".")]
    return [container_path] if os.path.exists(host_path) else []

for it in stalled:
    h = it["release_id"].split(":", 1)[1].lower()
    files = []
    t = rd.get(h)
    staged = None
    if t:
        staged = os.path.join(cfg["staging"], "realdebrid", t["filename"])
        files = payload_files(staged, "/downloads/realdebrid/" + t["filename"])
        if not files:
            staged = None
    if not files:
        p = qbit_path(h)
        if p:
            files = payload_files(p, p)   # /mnt is mounted at the same path
    if not files:
        continue
    imported = 0
    for f in files:
        res = romarr("/api/v1/manualimport", {"path": f, "platform": it.get("platform", "")})
        imported += len(res.get("imported") or [])
    if imported:
        q = romarr("/api/v1/queue").get("items", [])
        idx = next((i for i, x in enumerate(q) if x.get("release_id") == it["release_id"]), -1)
        if idx >= 0:
            romarr("/api/v1/queue/action", {"index": idx, "action": "remove"})
        # The import copied the payload; the RD staging copy is ours to drop
        # (only ever under <staging>/realdebrid/, never a client's own files)
        if staged and os.path.realpath(staged).startswith(
                os.path.realpath(os.path.join(cfg["staging"], "realdebrid")) + os.sep):
            import shutil
            shutil.rmtree(staged, ignore_errors=True) if os.path.isdir(staged) else os.remove(staged)
        print(f"recovered {it['release']!r} -> {imported} file(s) imported ({it.get('platform')})")
PYREC
}

_install_recover_cron() {
    cat >/etc/cron.d/romarr-recover <<CRON
# ROMarr stalled-import recovery (name-match bug in v1.0.0) — see romarr.sh
*/5 * * * * root bash ${SCRIPT_DIR}/romarr.sh --recover-stalled >>/var/log/romarr-recover.log 2>&1
CRON
    chmod 644 /etc/cron.d/romarr-recover
}

_show_status() {
    _api GET /api/v1/system/status | python3 -c "import json,sys
d=json.load(sys.stdin)
print('  version:  ', d.get('version'))
print('  prowlarr: ', 'ok' if d.get('prowlarr') else 'not configured', d.get('prowlarr_url',''))
print('  library:  ', 'ok' if d.get('library') else 'missing', d.get('library_path',''), '(RomM)' if d.get('romm') else '')
for c in d.get('clients',[]):
    print('  client:   ', c.get('name'), '/', c.get('protocol'), '-', 'ok' if c.get('ok') else 'FAIL '+(c.get('detail') or ''))" 2>/dev/null \
        || echo_warn "Could not read ${app_pretty} status"
}

# ==============================================================================
# App Installation
# ==============================================================================
_install_romarr() {
    mkdir -p "$app_configdir" "$app_stagingdir"
    chown "${user}:${user}" "$app_configdir" "$app_stagingdir"
    swizdb set "${app_name}/port" "$app_port"

    _write_env
    # A pre-existing .env (re-run) wins over the freshly allocated port
    app_port="$(_env_get ROMARR_PORT)"
    swizdb set "${app_name}/port" "$app_port"

    echo_progress_start "Generating Docker Compose configuration"
    _write_compose
    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling ${app_pretty} image"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull ${app_image}"
        exit 1
    }
    echo_progress_done "Image pulled"

    echo_progress_start "Starting ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "${app_pretty} container started"

    _wait_for_romarr
    _wire
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_romarr() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (ROM automation)
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

MemoryMax=${SYSTEMD_MEM_MAX:-2G}
CPUQuota=${SYSTEMD_CPU_QUOTA:-200%}
TasksMax=${SYSTEMD_TASKS_MAX:-2048}

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

    # ROMarr has its own login (password/API key) — no nginx basic auth.
    # Manual imports and backups can be large — no request size limit.
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

        # Live log tail / progress
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
#   not_installed → docker → container/env/wiring → systemd → cert → vhost → panel
#   unknown       → cert → vhost → panel (heals partial installs)
#   subdomain     → no-op (already configured)
_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${ROMARR_LE_HOSTNAME:-$domain}"
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
            _install_romarr
            _systemd_romarr
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
    echo_info "Web UI:    https://${domain}/"
    echo_info "Local:     http://127.0.0.1:${app_port}/"
    echo_info "Password:  grep ROMARR_PASSWORD ${app_envfile}"
    echo_info "API key:   grep ROMARR_API_KEY ${app_envfile}"
    echo ""
    echo_info "Integrations:"
    _show_status
    echo ""
    echo_info "Grabs land in $(_env_get LIBRARY_PATH)/<platform>/ and RomM is asked to scan."
    echo_info "Add a game: Wanted / Search in the UI, or GG Requestz / import lists."
    echo_info "Re-run wiring after installing another client: bash $0 --wire"
    echo ""
}

# ==============================================================================
# Update
# ==============================================================================
_update_romarr() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    echo_info "Updating ${app_pretty} (${app_image})..."
    app_port="$(_env_get ROMARR_PORT)"
    _write_compose

    echo_progress_start "Pulling ${app_pretty} image"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull ${app_image}"
        exit 1
    }
    echo_progress_done "Image pulled"

    echo_progress_start "Recreating ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"
    _wait_for_romarr

    docker image prune -f >>"$log" 2>&1 || true
    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_romarr() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig
    if ask "Purge configuration, history and staging downloads?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    echo_progress_start "Stopping ${app_pretty} container"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    docker rmi "$app_image" >>"$log" 2>&1 || true
    echo_progress_done "Container stopped"

    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload

    if [[ -L "$subdomain_enabled" ]] || [[ -f "$subdomain_vhost" ]]; then
        rm -f "$subdomain_enabled" "$subdomain_vhost"
        _reload_nginx 2>/dev/null || true
    fi

    _include_in_organizr

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        panel_unregister_app "$app_name"
    fi

    _nzbdav_remove_category
    rm -f /etc/cron.d/romarr-recover

    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration"
        rm -rf "$app_dir"
        echo_progress_done "Configuration purged"
        echo_info "The RomM 'romarr' user and library files are left untouched"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        swizdb clear "${app_name}/domain" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_dir}"
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
    echo "  (no args)              Interactive setup"
    echo "  --update               Pull the pinned image and recreate"
    echo "  --remove [--force]     Complete removal (prompts to purge config)"
    echo "  --register-panel       Re-register with swizzin panel"
    echo "  --wire                 (Re)add torrent clients (Real-Debrid, decypharr)"
    echo "  --status               Show integration status"
    echo "  --recover-stalled      Import downloads stuck at 'grabbed' (cron, every 5 min)"
    echo ""
    echo "Environment variable overrides:"
    echo "  ROMARR_DOMAIN          Subdomain (e.g. romarr.example.com)"
    echo "  ROMARR_LE_INTERACTIVE  yes|no — interactive Let's Encrypt mode (default: no)"
    echo "  ROMARR_LE_HOSTNAME     Request cert for a different hostname (e.g. wildcard)"
    echo "  ROMARR_VERSION         Image tag (default: 1.0.0)"
    echo "  ROMARR_RD_API_TOKEN    Real-Debrid token (default: the one decypharr uses)"
    echo "  ROMARR_LIBRARY_PATH    Library root when RomM is not installed"
    echo "  DOCKER_CPU_LIMIT / DOCKER_MEM_LIMIT / SYSTEMD_MEM_MAX / SYSTEMD_CPU_QUOTA"
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

# Port lives in .env once installed (ROMarr binds it directly, host network)
if [[ -f "$app_envfile" ]] && [[ -n "$(_env_get ROMARR_PORT)" ]]; then
    app_port="$(_env_get ROMARR_PORT)"
fi

case "${1:-}" in
    "--update")
        _update_romarr
        ;;
    "--remove")
        _remove_romarr "${2:-}"
        ;;
    "--wire")
        _wire
        _show_status
        exit 0
        ;;
    "--status")
        _show_status
        exit 0
        ;;
    "--recover-stalled")
        _recover_stalled
        exit 0
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        app_domain="$(_get_domain)"
        if [[ -z "$app_domain" ]]; then
            echo_error "No domain stored in swizdb for ${app_name}. Run the installer first or set ROMARR_DOMAIN."
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
