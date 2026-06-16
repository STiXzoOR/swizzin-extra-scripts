#!/bin/bash
set -euo pipefail
# lingarr installer
# STiXzoOR 2025
# Usage: bash lingarr.sh [--subdomain [--revert]|--update|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

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

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_nginx_symlink_created=""
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_nginx_symlink_created" ]] && rm -f "$_nginx_symlink_created"
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

app_name="lingarr"

# Get owner from swizdb (needed for both install and remove)
if ! LINGARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    LINGARR_OWNER="$(_get_master_username)"
fi
user="$LINGARR_OWNER"
app_group="$user"

# With host networking, the app always uses its internal port
app_port=9876

app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_configdir="$app_dir/config"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/lingarr.png"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# --- Function definitions ---

# ==============================================================================
# Domain / LE / State Helpers
# ==============================================================================

_get_organizr_domain() {
    if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
        grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
    fi
}

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "${app_name}/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${LINGARR_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${LINGARR_DOMAIN:-}" ]; then
        echo_info "Using domain from LINGARR_DOMAIN: $LINGARR_DOMAIN"
        app_domain="$LINGARR_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Lingarr" "[$existing_domain]"
    else
        echo_query "Enter domain for Lingarr" "(e.g., lingarr.example.com)"
    fi
    read -r input_domain </dev/tty

    if [ -z "$input_domain" ]; then
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
    export LINGARR_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${LINGARR_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from LINGARR_LE_INTERACTIVE: $LINGARR_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export LINGARR_LE_INTERACTIVE="yes"
    else
        export LINGARR_LE_INTERACTIVE="no"
    fi
}

_get_install_state() {
    if [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo "not_installed"
    elif [ -f "$subdomain_vhost" ]; then
        echo "subdomain"
    else
        echo "installed"
    fi
}

# ==============================================================================
# Backup Helpers
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
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    local le_hostname="${LINGARR_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${LINGARR_LE_INTERACTIVE:-no}"

    if [ -d "$cert_dir" ]; then
        echo_info "Let's Encrypt certificate already exists for $le_hostname"
        return 0
    fi

    echo_info "Requesting Let's Encrypt certificate for $le_hostname"

    if [ "$le_interactive" = "yes" ]; then
        echo_info "Running Let's Encrypt in interactive mode..."
        LE_HOSTNAME="$le_hostname" box install letsencrypt </dev/tty
        local result=$?
    else
        LE_HOSTNAME="$le_hostname" LE_DEFAULTCONF=no LE_BOOL_CF=no \
            box install letsencrypt >>"$log" 2>&1
        local result=$?
    fi

    if [ $result -ne 0 ]; then
        echo_error "Failed to obtain Let's Encrypt certificate for $le_hostname"
        echo_error "Check $log for details or run manually: LE_HOSTNAME=$le_hostname box install letsencrypt"
        exit 1
    fi

    echo_info "Let's Encrypt certificate issued for $le_hostname"
}

# ==============================================================================
# Organizr Integration
# ==============================================================================

_exclude_from_organizr() {
    local modified=false
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"

    if [ -f "$organizr_config" ] && grep -q "^${app_name}:" "$organizr_config"; then
        echo_progress_start "Removing ${app_name^} from Organizr protected apps"
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
        echo_info "Note: ${app_name^} can be re-added to Organizr protection via: bash organizr.sh --configure"
    fi
}

# ==============================================================================
# Docker / Discovery / Install Functions
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

_discover_media_paths() {
    MEDIA_PATHS=()
    MEDIA_MOUNT_NAMES=()
    local -A seen_paths=()

    echo_progress_start "Discovering media paths from Sonarr/Radarr"

    # Scan for arr lock files and query their databases (requires sqlite3)
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo_info "sqlite3 not found, skipping database auto-discovery"
    else
        for lock in /install/.sonarr.lock /install/.sonarr_*.lock /install/.radarr.lock /install/.radarr_*.lock; do
            [[ -f "$lock" ]] || continue

            local lock_basename
            lock_basename=$(basename "$lock" .lock)
            lock_basename="${lock_basename#.}" # Remove leading dot

            # Determine config directory name
            local config_dir_name
            case "$lock_basename" in
                sonarr) config_dir_name="Sonarr" ;;
                radarr) config_dir_name="Radarr" ;;
                sonarr_*)
                    local instance="${lock_basename#sonarr_}"
                    config_dir_name="sonarr-${instance}"
                    ;;
                radarr_*)
                    local instance="${lock_basename#radarr_}"
                    config_dir_name="radarr-${instance}"
                    ;;
                *) continue ;;
            esac

            # Find the database file
            for db in /home/*/.config/"${config_dir_name}"/*.db; do
                [[ -f "$db" ]] || continue
                # Query root folders
                while IFS= read -r path; do
                    [[ -z "$path" ]] && continue
                    # Remove trailing slash for consistency
                    path="${path%/}"
                    if [[ -z "${seen_paths[$path]+x}" ]]; then
                        seen_paths["$path"]=1
                        MEDIA_PATHS+=("$path")
                    fi
                done < <(sqlite3 "$db" "SELECT Path FROM RootFolders;" 2>/dev/null)
            done
        done
    fi # sqlite3 check

    echo_progress_done "Discovery complete"

    # Use full paths as mount names so Lingarr sees the same paths as Sonarr/Radarr
    for path in "${MEDIA_PATHS[@]}"; do
        MEDIA_MOUNT_NAMES+=("$path")
    done

    # Display discovered paths
    if [[ ${#MEDIA_PATHS[@]} -gt 0 ]]; then
        echo_info "Discovered media paths:"
        for i in "${!MEDIA_PATHS[@]}"; do
            echo_info "  ${MEDIA_PATHS[$i]} -> ${MEDIA_MOUNT_NAMES[$i]}"
        done

        if ! ask "Use these paths?" Y; then
            MEDIA_PATHS=()
            MEDIA_MOUNT_NAMES=()
        fi
    else
        echo_info "No Sonarr/Radarr installations found for auto-discovery"
    fi

    # Allow adding additional paths (or all paths if none discovered/confirmed)
    while true; do
        if [[ ${#MEDIA_PATHS[@]} -eq 0 ]]; then
            echo_query "Enter a media path (e.g., /mnt/media/movies, or leave empty to cancel)" ""
        else
            if ! ask "Add another media path?" N; then
                break
            fi
            echo_query "Enter the media path (or leave empty to skip)" ""
        fi

        local new_path
        read -r new_path </dev/tty
        if [[ -z "$new_path" ]]; then
            [[ ${#MEDIA_PATHS[@]} -gt 0 ]] && break
            echo_info "No path entered"
            continue
        fi

        new_path="${new_path%/}"

        if [[ -n "${seen_paths[$new_path]+x}" ]]; then
            echo_info "Path already added, skipping"
            continue
        fi

        seen_paths["$new_path"]=1
        MEDIA_PATHS+=("$new_path")
        MEDIA_MOUNT_NAMES+=("$new_path")

        echo_info "Added: $new_path"
    done

    if [[ ${#MEDIA_PATHS[@]} -eq 0 ]]; then
        echo_error "At least one media path is required"
        exit 1
    fi
}

_discover_arr_api() {
    SONARR_URL=""
    SONARR_API_KEY=""
    RADARR_URL=""
    RADARR_API_KEY=""

    # Only discover one Sonarr and one Radarr instance (base preferred).
    # Lingarr's web UI can be used to configure additional instances.

    # Try Sonarr (base first, then multi-instance)
    local sonarr_config=""
    if [[ -f /install/.sonarr.lock ]]; then
        for cfg in /home/*/.config/Sonarr/config.xml; do
            [[ -f "$cfg" ]] && sonarr_config="$cfg" && break
        done
    fi
    if [[ -z "$sonarr_config" ]]; then
        for lock in /install/.sonarr_*.lock; do
            [[ -f "$lock" ]] || continue
            local instance="${lock##*/}"
            instance="${instance#.sonarr_}"
            instance="${instance%.lock}"
            for cfg in /home/*/.config/sonarr-"${instance}"/config.xml; do
                [[ -f "$cfg" ]] && sonarr_config="$cfg" && break 2
            done
        done
    fi

    if [[ -n "$sonarr_config" ]]; then
        local api_key port url_base
        api_key=$(grep -oP '<ApiKey>\K[^<]+' "$sonarr_config" 2>/dev/null) || true
        port=$(grep -oP '<Port>\K[^<]+' "$sonarr_config" 2>/dev/null) || true
        url_base=$(grep -oP '<UrlBase>\K[^<]+' "$sonarr_config" 2>/dev/null) || true
        if [[ -n "$api_key" && -n "$port" ]]; then
            # Use 127.0.0.1 with host networking, include UrlBase if configured
            SONARR_URL="http://127.0.0.1:${port}${url_base}"
            SONARR_API_KEY="$api_key"
            echo_info "Discovered Sonarr at http://127.0.0.1:${port}${url_base}"
        fi
    fi

    # Try Radarr (base first, then multi-instance)
    local radarr_config=""
    if [[ -f /install/.radarr.lock ]]; then
        for cfg in /home/*/.config/Radarr/config.xml; do
            [[ -f "$cfg" ]] && radarr_config="$cfg" && break
        done
    fi
    if [[ -z "$radarr_config" ]]; then
        for lock in /install/.radarr_*.lock; do
            [[ -f "$lock" ]] || continue
            local instance="${lock##*/}"
            instance="${instance#.radarr_}"
            instance="${instance%.lock}"
            for cfg in /home/*/.config/radarr-"${instance}"/config.xml; do
                [[ -f "$cfg" ]] && radarr_config="$cfg" && break 2
            done
        done
    fi

    if [[ -n "$radarr_config" ]]; then
        local api_key port url_base
        api_key=$(grep -oP '<ApiKey>\K[^<]+' "$radarr_config" 2>/dev/null) || true
        port=$(grep -oP '<Port>\K[^<]+' "$radarr_config" 2>/dev/null) || true
        url_base=$(grep -oP '<UrlBase>\K[^<]+' "$radarr_config" 2>/dev/null) || true
        if [[ -n "$api_key" && -n "$port" ]]; then
            # Use 127.0.0.1 with host networking, include UrlBase if configured
            RADARR_URL="http://127.0.0.1:${port}${url_base}"
            RADARR_API_KEY="$api_key"
            echo_info "Discovered Radarr at http://127.0.0.1:${port}${url_base}"
        fi
    fi
}

_install_lingarr() {
    mkdir -p "$app_configdir"
    chown -R "${user}:${user}" "$app_dir"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    echo_progress_start "Generating Docker Compose configuration"

    # Write docker-compose.yml with proper YAML formatting
    # Use host networking to avoid UFW/Docker firewall conflicts
    {
        cat <<COMPOSE
services:
  lingarr:
    image: lingarr/lingarr:latest
    container_name: lingarr
    restart: unless-stopped
    user: "${uid}:${gid}"
    network_mode: host
    environment:
      - ASPNETCORE_URLS=http://127.0.0.1:${app_port}
      - DB_CONNECTION=sqlite
COMPOSE
        if [[ -n "${SONARR_URL:-}" ]]; then
            echo "      - SONARR_URL=${SONARR_URL}"
            echo "      - SONARR_API_KEY=${SONARR_API_KEY}"
        fi
        if [[ -n "${RADARR_URL:-}" ]]; then
            echo "      - RADARR_URL=${RADARR_URL}"
            echo "      - RADARR_API_KEY=${RADARR_API_KEY}"
        fi
        echo "    volumes:"
        echo "      - ${app_configdir}:/app/config"
        for i in "${!MEDIA_PATHS[@]}"; do
            echo "      - ${MEDIA_PATHS[$i]}:${MEDIA_MOUNT_NAMES[$i]}"
        done
    } >"$app_dir/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling Lingarr Docker image"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting Lingarr container"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "Lingarr container started"
}

_systemd_lingarr() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=Lingarr (Subtitle Translation)
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

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

_nginx_lingarr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_baseurl {
			  return 301 /$app_baseurl/;
			}

			location ^~ /$app_baseurl/ {
			    proxy_pass http://127.0.0.1:$app_port/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect off;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Disable upstream compression so sub_filter can rewrite
			    proxy_set_header Accept-Encoding "";

			    # Rewrite URLs in responses (Lingarr has no base_url support)
			    sub_filter_once off;
			    sub_filter_types text/css text/javascript application/javascript application/json;

			    # HTML attributes (both quote styles)
			    sub_filter 'href="/' 'href="/$app_baseurl/';
			    sub_filter "href='/" "href='/$app_baseurl/";
			    sub_filter 'src="/' 'src="/$app_baseurl/';
			    sub_filter "src='/" "src='/$app_baseurl/";
			    sub_filter 'action="/' 'action="/$app_baseurl/';
			    sub_filter "action='/" "action='/$app_baseurl/";
			    sub_filter 'url(/' 'url(/$app_baseurl/';

			    # API endpoints (35+ endpoints all under /api/*)
			    sub_filter '"/api/' '"/$app_baseurl/api/';
			    sub_filter "'/api/" "'/$app_baseurl/api/";
			    sub_filter '("/api/' '("/$app_baseurl/api/';
			    sub_filter "('/api/" "('/$app_baseurl/api/";

			    # SignalR WebSocket hub (/signalr/TranslationRequests)
			    sub_filter '"/signalr' '"/$app_baseurl/signalr';
			    sub_filter "'/signalr" "'/$app_baseurl/signalr";
			    sub_filter '("/signalr' '("/$app_baseurl/signalr';
			    sub_filter "('/signalr" "('/$app_baseurl/signalr";

			    # Fetch API calls
			    sub_filter 'fetch("/' 'fetch("/$app_baseurl/';
			    sub_filter "fetch('/" "fetch('/$app_baseurl/";

			    # Vite dynamic imports (code splitting)
			    sub_filter 'import("/' 'import("/$app_baseurl/';
			    sub_filter "import('/" "import('/$app_baseurl/";

			    # Vite preload hints and asset paths (absolute)
			    sub_filter '"/assets/' '"/$app_baseurl/assets/';
			    sub_filter "'/assets/" "'/$app_baseurl/assets/";

			    # Vite __vite__mapDeps array (relative paths without leading slash)
			    # Note: No leading / because Vite prepends base "/" -> would create "//lingarr/"
			    sub_filter '"assets/' '"$app_baseurl/assets/';
			    sub_filter "'assets/" "'$app_baseurl/assets/";

			    # Inject <base> tag so Vue Router picks up the subpath
			    # Note: Don't rewrite router path configs - <base> tag handles routing
			    sub_filter '</head>' '<base href="/$app_baseurl/"></head>';

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /$app_baseurl/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/api;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
    fi
}

# ==============================================================================
# Fresh Install (subfolder mode)
# ==============================================================================

_install_fresh() {
    if [[ -f "/install/.$app_lockname.lock" ]]; then
        echo_info "${app_name^} already installed"
        return
    fi

    # Set owner for install
    if [[ -n "${LINGARR_OWNER:-}" ]]; then
        echo_info "Setting ${app_name^} owner = $LINGARR_OWNER"
        swizdb set "$app_name/owner" "$LINGARR_OWNER"
    fi

    _install_docker
    _discover_media_paths
    _discover_arr_api
    _install_lingarr
    _systemd_lingarr
    _nginx_lingarr

    # Panel registration (subfolder mode)
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "Lingarr" \
            "/$app_baseurl" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    fi

    touch "/install/.$app_lockname.lock"
    echo_success "${app_name^} installed"
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

    ${csp_header}

    location / {
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
    }
}
VHOST

    [ -L "$subdomain_enabled" ] || ln -s "$subdomain_vhost" "$subdomain_enabled"

    echo_progress_done "Subdomain vhost created"
}

# ==============================================================================
# Panel Meta Management
# ==============================================================================

_add_panel_meta() {
    local domain="$1"

    echo_progress_start "Adding panel meta urloverride"

    mkdir -p "$(dirname "$profiles_py")"
    touch "$profiles_py"

    # Remove existing class if present (standalone class, not inheritance)
    sed -i "/^class ${app_name}_meta:/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

    # Lingarr is NOT a built-in Swizzin app, so create standalone class (no inheritance)
    cat >>"$profiles_py" <<PYTHON

class ${app_name}_meta:
    name = "${app_name}"
    pretty_name = "Lingarr"
    urloverride = "https://${domain}"
    systemd = "${app_name}"
    img = "${app_icon_name}"
    check_theD = True
PYTHON

    echo_progress_done "Panel meta updated"
}

_remove_panel_meta() {
    if [ -f "$profiles_py" ]; then
        echo_progress_start "Removing panel meta urloverride"
        # Remove standalone class (not inheritance)
        sed -i "/^class ${app_name}_meta:/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
        echo_progress_done "Panel meta removed"
    fi
}

# ==============================================================================
# Subdomain Install / Revert
# ==============================================================================

_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${LINGARR_LE_HOSTNAME:-$domain}"
    local state
    state=$(_get_install_state)

    echo_info "${app_name^} Subdomain Setup"
    echo_info "Domain: $domain"
    [ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
    echo_info "Current state: $state"

    case "$state" in
        "not_installed")
            _install_fresh
            ;& # fallthrough
        "installed")
            # Backup subfolder config before switching
            _backup_file "/etc/nginx/apps/$app_name.conf"
            # Remove subfolder config (subdomain replaces it)
            _remove_nginx_conf "$app_name"
            _request_certificate "$domain"
            _create_subdomain_vhost "$domain" "$le_hostname"
            _add_panel_meta "$domain"
            _exclude_from_organizr
            _reload_nginx
            echo_success "${app_name^} converted to subdomain mode"
            echo_info "Access at: https://$domain"
            ;;
        "subdomain")
            echo_info "Already in subdomain mode"
            ;;
    esac
}

_revert_subdomain() {
    echo_info "Reverting ${app_name^} to subfolder mode..."

    [ -L "$subdomain_enabled" ] && rm -f "$subdomain_enabled"
    [ -f "$subdomain_vhost" ] && rm -f "$subdomain_vhost"

    # Restore subfolder nginx config
    if [ -f "$backup_dir/$app_name.conf.bak" ]; then
        cp "$backup_dir/$app_name.conf.bak" "/etc/nginx/apps/$app_name.conf"
        echo_info "Restored subfolder nginx config from backup"
    elif [ -f /install/.nginx.lock ]; then
        echo_info "Recreating subfolder config..."
        _nginx_lingarr
    fi

    _remove_panel_meta
    _include_in_organizr

    _reload_nginx
    echo_success "${app_name^} reverted to subfolder mode"
    echo_info "Access at: https://your-server/lingarr/"
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo_info "${app_name^} Setup"

    local state
    state=$(_get_install_state)

    if [ "$state" = "not_installed" ]; then
        _install_fresh
        state="installed"
    else
        echo_info "${app_name^} already installed"
    fi

    if [ "$state" = "installed" ]; then
        if [ -f /install/.nginx.lock ]; then
            if ask "Configure Lingarr with a subdomain? (recommended for cleaner URLs)" N; then
                _install_subdomain
            fi
        fi
    elif [ "$state" = "subdomain" ]; then
        echo_info "Subdomain already configured"
    fi

    echo_success "${app_name^} setup complete"
}

# ==============================================================================
# Usage
# ==============================================================================

_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  (no args)             Interactive setup"
    echo "  --subdomain           Convert to subdomain mode"
    echo "  --subdomain --revert  Revert to subfolder mode"
    echo "  --update [--verbose]  Pull latest Docker image"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
}

# ==============================================================================
# Update
# ==============================================================================

_update_lingarr() {
    if [[ ! -f "/install/.$app_lockname.lock" ]]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_name^}..."

    echo_progress_start "Pulling latest Lingarr image"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating Lingarr container"
    _verbose "Running: docker compose up -d"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_name^} has been updated"
    exit 0
}

_remove_lingarr() {
    local force="$1"
    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.$app_lockname.lock" ]]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Ask about purging configuration
    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove container
    echo_progress_start "Stopping Lingarr container"
    if [[ -f "$app_dir/docker-compose.yml" ]]; then
        docker compose -f "$app_dir/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi lingarr/lingarr >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/$app_servicefile"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove subfolder nginx config
    if [[ -f "/etc/nginx/apps/$app_name.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        _remove_nginx_conf "$app_name"
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove subdomain vhost if exists
    if [ -f "$subdomain_vhost" ] || [ -L "$subdomain_enabled" ]; then
        echo_progress_start "Removing subdomain nginx configuration"
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        echo_progress_done "Subdomain configuration removed"
    fi

    _reload_nginx 2>/dev/null || true

    # Remove panel meta (subdomain mode)
    _remove_panel_meta

    # Remove from panel (subfolder mode)
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Remove backup dir
    rm -rf "$backup_dir"

    # Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "$app_name/owner" 2>/dev/null || true
        swizdb clear "$app_name/port" 2>/dev/null || true
        swizdb clear "$app_name/domain" 2>/dev/null || true
    else
        echo_info "Configuration kept at: $app_configdir"
        rm -f "$app_dir/docker-compose.yml"
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
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
    "--subdomain")
        case "${2:-}" in
            "--revert") _revert_subdomain ;;
            "") _install_subdomain ;;
            *) _usage ;;
        esac
        ;;
    "--update")
        _update_lingarr
        ;;
    "--remove")
        _remove_lingarr "$2"
        ;;
    "--register-panel")
        if [[ ! -f "/install/.$app_lockname.lock" ]]; then
            echo_error "${app_name^} is not installed"
            exit 1
        fi
        state=$(_get_install_state)
        if [ "$state" = "subdomain" ]; then
            domain=$(_get_domain)
            if [ -n "$domain" ]; then
                _add_panel_meta "$domain"
            else
                echo_error "No domain configured"
                exit 1
            fi
        else
            _load_panel_helper
            if command -v panel_register_app >/dev/null 2>&1; then
                panel_register_app \
                    "$app_name" \
                    "Lingarr" \
                    "/$app_baseurl" \
                    "" \
                    "$app_name" \
                    "$app_icon_name" \
                    "$app_icon_url" \
                    "true"
            else
                echo_error "Panel helper not available"
                exit 1
            fi
        fi
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_name^}"
        ;;
    "")
        _interactive
        ;;
    *)
        _usage
        ;;
esac
