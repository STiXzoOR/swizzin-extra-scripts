#!/bin/bash
set -euo pipefail
# mdblistarr installer
# STiXzoOR 2026
# Usage: bash mdblistarr.sh [--subdomain [--revert]|--update|--remove [--force]|--register-panel]

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

app_name="mdblistarr"

# Get owner from swizdb (needed for both install and remove)
if ! MDBLISTARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    MDBLISTARR_OWNER="$(_get_master_username)"
fi
user="$MDBLISTARR_OWNER"
app_group="$user"

# Port allocation: read from swizdb or allocate new
if _existing_port="$(swizdb get "$app_name/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_dbdir="$app_dir/db"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/mdblistarr.png"

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
    echo "${MDBLISTARR_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${MDBLISTARR_DOMAIN:-}" ]; then
        echo_info "Using domain from MDBLISTARR_DOMAIN: $MDBLISTARR_DOMAIN"
        app_domain="$MDBLISTARR_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for MDBListarr" "[$existing_domain]"
    else
        echo_query "Enter domain for MDBListarr" "(e.g., mdblistarr.example.com)"
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
    export MDBLISTARR_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${MDBLISTARR_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from MDBLISTARR_LE_INTERACTIVE: $MDBLISTARR_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export MDBLISTARR_LE_INTERACTIVE="yes"
    else
        export MDBLISTARR_LE_INTERACTIVE="no"
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
    local le_hostname="${MDBLISTARR_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${MDBLISTARR_LE_INTERACTIVE:-no}"

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
# Docker / Install Functions
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

_install_mdblistarr() {
    mkdir -p "$app_dbdir"

    # Create Django settings override to trust nginx reverse proxy headers
    cat >"$app_dbdir/settings_override.py" <<'SETTINGS'
from mdblist.settings import *  # noqa: F401,F403

# Trust nginx reverse proxy headers so Django sees the real host/proto
USE_X_FORWARDED_HOST = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SETTINGS

    echo_progress_start "Generating Docker Compose configuration"

    cat >"$app_dir/docker-compose.yml" <<COMPOSE
services:
  mdblistarr:
    image: linaspurinis/mdblistarr:latest
    container_name: mdblistarr
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${app_dbdir}:/usr/src/db
    environment:
      - PORT=${app_port}
      - PYTHONPATH=/usr/src/db:/usr/src/app
      - DJANGO_SETTINGS_MODULE=settings_override
COMPOSE

    echo_progress_done "Docker Compose configuration generated"

    # Persist port in swizdb (owner is set in _install_fresh)
    swizdb set "$app_name/port" "$app_port"

    echo_progress_start "Pulling MDBListarr Docker image"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting MDBListarr container"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "MDBListarr container started"
}

_systemd_mdblistarr() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=MDBListarr (MDBList.com Sonarr/Radarr Integration)
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

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

_nginx_mdblistarr() {
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
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Rewrite redirect headers (Django HttpResponseRedirect sends Location: /)
			    proxy_redirect / /$app_baseurl/;

			    # Disable upstream compression so sub_filter can rewrite
			    proxy_set_header Accept-Encoding "";

			    # Rewrite URLs in responses (Django has no FORCE_SCRIPT_NAME support)
			    sub_filter_once off;
			    sub_filter_types text/javascript application/javascript;

			    # Navigation links (layout.html)
			    sub_filter 'href="/"' 'href="/$app_baseurl/"';
			    sub_filter 'href="/log"' 'href="/$app_baseurl/log"';

			    # Form actions (index.html — Django {% url 'home_view' %} resolves to /)
			    sub_filter 'action="/"' 'action="/$app_baseurl/"';

			    # AJAX endpoints (index.html JavaScript)
			    sub_filter "'/set_active_tab/'" "'/$app_baseurl/set_active_tab/'";
			    sub_filter "'/test_radarr_connection/'" "'/$app_baseurl/test_radarr_connection/'";
			    sub_filter "'/test_sonarr_connection/'" "'/$app_baseurl/test_sonarr_connection/'";

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}
		NGX

        _nginx_config_written="/etc/nginx/apps/$app_name.conf"
        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
    fi
}

# ==============================================================================
# Sonarr/Radarr Auto-Discovery (display only)
# ==============================================================================

_discover_arr_instances() {
    local found=false

    echo ""
    echo_info "Scanning for Sonarr/Radarr instances..."

    # Scan all sonarr/radarr lock files
    for lock in /install/.sonarr.lock /install/.sonarr_*.lock /install/.radarr.lock /install/.radarr_*.lock; do
        [[ -f "$lock" ]] || continue

        local lock_basename
        lock_basename=$(basename "$lock" .lock)
        lock_basename="${lock_basename#.}" # Remove leading dot

        # Determine config directory name and display name
        local config_dir_name display_name
        case "$lock_basename" in
            sonarr)
                config_dir_name="Sonarr"
                display_name="sonarr"
                ;;
            radarr)
                config_dir_name="Radarr"
                display_name="radarr"
                ;;
            sonarr_*)
                local instance="${lock_basename#sonarr_}"
                config_dir_name="sonarr-${instance}"
                display_name="sonarr-${instance}"
                ;;
            radarr_*)
                local instance="${lock_basename#radarr_}"
                config_dir_name="radarr-${instance}"
                display_name="radarr-${instance}"
                ;;
            *) continue ;;
        esac

        # Find config.xml
        for cfg in /home/*/.config/"${config_dir_name}"/config.xml; do
            [[ -f "$cfg" ]] || continue

            local api_key port url_base
            api_key=$(grep -oP '<ApiKey>\K[^<]+' "$cfg" 2>/dev/null) || true
            port=$(grep -oP '<Port>\K[^<]+' "$cfg" 2>/dev/null) || true
            url_base=$(grep -oP '<UrlBase>\K[^<]+' "$cfg" 2>/dev/null) || true

            if [[ -n "$api_key" && -n "$port" ]]; then
                if [[ "$found" == "false" ]]; then
                    echo ""
                    echo_info "Detected Sonarr/Radarr instances:"
                    found=true
                fi
                printf "  %-20s http://127.0.0.1:%s%s  API: %s\n" "${display_name}:" "${port}" "/${url_base#/}" "$api_key"
            fi
            break
        done
    done

    echo ""
    if [[ "$found" == "true" ]]; then
        echo_info "Enter these in the MDBListarr web UI to connect your instances."
    else
        echo_info "No Sonarr/Radarr instances detected. Configure them in the MDBListarr web UI."
    fi

    echo ""
    echo_info "Default credentials: admin / admin"
    echo_warn "Change the default password after first login!"
}

# ==============================================================================
# Fresh Install (subfolder mode)
# ==============================================================================

_install_fresh() {
    if [[ -f "/install/.$app_lockname.lock" ]]; then
        echo_info "${app_name^} already installed"
        return
    fi

    _cleanup_needed=true

    # Set owner for install
    if [[ -n "${MDBLISTARR_OWNER:-}" ]]; then
        echo_info "Setting ${app_name^} owner = $MDBLISTARR_OWNER"
        swizdb set "$app_name/owner" "$MDBLISTARR_OWNER"
    fi

    _install_docker
    _install_mdblistarr
    _systemd_mdblistarr
    _nginx_mdblistarr
    _discover_arr_instances

    # Panel registration (subfolder mode)
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "MDBListarr" \
            "/$app_baseurl" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    fi

    touch "/install/.$app_lockname.lock"
    _lock_file_created="/install/.$app_lockname.lock"
    _cleanup_needed=false
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

    # Create upstream block with keepalive for connection pooling
    cat >/etc/nginx/conf.d/upstream-${app_name}.conf <<UPSTREAM
upstream ${app_name}_backend {
    server 127.0.0.1:${app_port};
    keepalive 32;
}
UPSTREAM

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
        proxy_pass http://${app_name}_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_set_header Upgrade \$http_upgrade;
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

    # MDBListarr is NOT a built-in Swizzin app, so create standalone class (no inheritance)
    cat >>"$profiles_py" <<PYTHON

class ${app_name}_meta:
    name = "${app_name}"
    pretty_name = "MDBListarr"
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
    local le_hostname="${MDBLISTARR_LE_HOSTNAME:-$domain}"
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
    rm -f "/etc/nginx/conf.d/upstream-${app_name}.conf"

    # Restore subfolder nginx config
    if [ -f "$backup_dir/$app_name.conf.bak" ]; then
        cp "$backup_dir/$app_name.conf.bak" "/etc/nginx/apps/$app_name.conf"
        echo_info "Restored subfolder nginx config from backup"
    elif [ -f /install/.nginx.lock ]; then
        echo_info "Recreating subfolder config..."
        _nginx_mdblistarr
    fi

    _remove_panel_meta
    _include_in_organizr

    _reload_nginx
    echo_success "${app_name^} reverted to subfolder mode"
    echo_info "Access at: https://your-server/mdblistarr/"
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
            if ask "Configure MDBListarr with a subdomain? (recommended for cleaner URLs)" N; then
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

_update_mdblistarr() {
    if [[ ! -f "/install/.$app_lockname.lock" ]]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_name^}..."

    echo_progress_start "Pulling latest MDBListarr image"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating MDBListarr container"
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

# ==============================================================================
# Remove
# ==============================================================================

_remove_mdblistarr() {
    local force="$1"
    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.$app_lockname.lock" ]]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Ask about purging configuration (skip prompt if --force)
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove container
    echo_progress_start "Stopping MDBListarr container"
    if [[ -f "$app_dir/docker-compose.yml" ]]; then
        docker compose -f "$app_dir/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi linaspurinis/mdblistarr >>"$log" 2>&1 || true
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

    # Remove subdomain vhost and upstream if exists
    if [ -f "$subdomain_vhost" ] || [ -L "$subdomain_enabled" ]; then
        echo_progress_start "Removing subdomain nginx configuration"
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        rm -f "/etc/nginx/conf.d/upstream-${app_name}.conf"
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
        echo_info "Configuration kept at: $app_dbdir"
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
        _update_mdblistarr
        ;;
    "--remove")
        _remove_mdblistarr "${2:-}"
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
                    "MDBListarr" \
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
