#!/bin/bash
set -euo pipefail
# plex - Extended Plex installer with subdomain support
# STiXzoOR 2025
# Usage: bash plex.sh [--subdomain [--revert]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true
# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

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

app_name="plex"
app_port="32400"
app_lockname="plex"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"
plex_prefs="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"

# ==============================================================================
# Domain/LE Helper Functions
# ==============================================================================

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "plex/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${PLEX_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${PLEX_DOMAIN:-}" ]; then
        echo_info "Using domain from PLEX_DOMAIN: $PLEX_DOMAIN"
        app_domain="$PLEX_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Plex" "[$existing_domain]"
    else
        echo_query "Enter domain for Plex" "(e.g., plex.example.com)"
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
    swizdb set "plex/domain" "$app_domain"
    export PLEX_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${PLEX_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from PLEX_LE_INTERACTIVE: $PLEX_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export PLEX_LE_INTERACTIVE="yes"
    else
        export PLEX_LE_INTERACTIVE="no"
    fi
}

# ==============================================================================
# Organizr Integration
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
# State Detection
# ==============================================================================

_get_install_state() {
    if [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo "not_installed"
    elif [ -f "$subdomain_vhost" ]; then
        echo "subdomain"
    elif [ -f "$subfolder_conf" ]; then
        echo "subfolder"
    else
        echo "unknown"
    fi
}

# ==============================================================================
# Base App Installation
# ==============================================================================

_install_app() {
    if [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo_info "Installing ${app_name^} via box install ${app_name}..."
        box install "$app_name" || {
            echo_error "Failed to install ${app_name^}"
            exit 1
        }
    else
        echo_info "${app_name^} already installed"
    fi
}

# ==============================================================================
# Nginx Subfolder Config
# ==============================================================================

_create_subfolder_config() {
    cat >"$subfolder_conf" <<-'NGX'
		location /plex {
		    return 301 $scheme://$host/plex/;
		}

		location ^~ /plex/ {
		    rewrite /plex/(.*) /$1 break;
		    include /etc/nginx/snippets/proxy.conf;
		    proxy_pass http://127.0.0.1:32400;

		    proxy_set_header X-Plex-Client-Identifier $http_x_plex_client_identifier;
		    proxy_set_header X-Plex-Device $http_x_plex_device;
		    proxy_set_header X-Plex-Device-Name $http_x_plex_device_name;
		    proxy_set_header X-Plex-Platform $http_x_plex_platform;
		    proxy_set_header X-Plex-Platform-Version $http_x_plex_platform_version;
		    proxy_set_header X-Plex-Product $http_x_plex_product;
		    proxy_set_header X-Plex-Token $http_x_plex_token;
		    proxy_set_header X-Plex-Version $http_x_plex_version;
		    proxy_set_header X-Plex-Nocache $http_x_plex_nocache;
		    proxy_set_header X-Plex-Provides $http_x_plex_provides;
		    proxy_set_header X-Plex-Device-Vendor $http_x_plex_device_vendor;
		    proxy_set_header X-Plex-Model $http_x_plex_model;
		}

		if ($http_referer ~* /plex) {
		    rewrite ^/web/(.*) /plex/web/$1? redirect;
		}
	NGX
}

_nginx_subfolder() {
    if [ -f "$subfolder_conf" ]; then
        echo_info "nginx subfolder config already exists"
        return
    fi

    echo_progress_start "Creating nginx subfolder config"
    _create_subfolder_config
    _reload_nginx
    echo_progress_done "nginx configured for /plex/"
}

# ==============================================================================
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    local le_hostname="${PLEX_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${PLEX_LE_INTERACTIVE:-no}"

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
# Plex Preferences
# ==============================================================================

_set_plex_pref() {
    local key="$1"
    local value
    value=$(_sed_escape_value "$2")
    if grep -q "${key}=" "$plex_prefs"; then
        sed -i "s|${key}=\"[^\"]*\"|${key}=\"${value}\"|" "$plex_prefs"
    else
        sed -i "s|/>| ${key}=\"${value}\" />|" "$plex_prefs"
    fi
}

_remove_plex_pref() {
    local key="$1"
    if grep -q "${key}=" "$plex_prefs"; then
        sed -i "s| ${key}=\"[^\"]*\"||" "$plex_prefs"
    fi
}

_configure_plex_preferences() {
    local domain="$1"
    local custom_url="https://${domain}:443"

    if [ ! -f "$plex_prefs" ]; then
        echo_error "Plex Preferences.xml not found at: $plex_prefs"
        return 1
    fi

    echo_progress_start "Configuring Plex server preferences"

    # Stop Plex to safely edit preferences (Plex overwrites on shutdown)
    systemctl stop plexmediaserver

    _set_plex_pref "customConnections" "$custom_url"
    _set_plex_pref "secureConnections" "1"

    systemctl start plexmediaserver

    echo_progress_done "Plex configured: customConnections=${custom_url}, secureConnections=Preferred"
}

_reset_plex_preferences() {
    if [ ! -f "$plex_prefs" ]; then
        return 0
    fi

    echo_progress_start "Resetting Plex server preferences"

    systemctl stop plexmediaserver

    _remove_plex_pref "customConnections"

    systemctl start plexmediaserver

    echo_progress_done "Plex preferences reset"
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

    # Create shared map for WebSocket + keepalive compatibility
    if [[ ! -f /etc/nginx/conf.d/map-connection-upgrade.conf ]]; then
        cat >/etc/nginx/conf.d/map-connection-upgrade.conf <<'MAPCONF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}
MAPCONF
    fi

    # Create upstream block with keepalive for connection pooling
    cat >/etc/nginx/conf.d/upstream-plex.conf <<UPSTREAM
upstream plex_backend {
    server 127.0.0.1:${app_port};
    keepalive 32;
}
UPSTREAM

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
    proxy_redirect off;
    proxy_buffering off;

    # Streaming timeouts (1 hour for long-running streams)
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    ${csp_header}

    location / {
        include snippets/proxy.conf;
        proxy_pass http://plex_backend/;
        proxy_http_version 1.1;

        # WebSocket support with keepalive compatibility
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header X-Plex-Client-Identifier \$http_x_plex_client_identifier;
        proxy_set_header X-Plex-Device \$http_x_plex_device;
        proxy_set_header X-Plex-Device-Name \$http_x_plex_device_name;
        proxy_set_header X-Plex-Platform \$http_x_plex_platform;
        proxy_set_header X-Plex-Platform-Version \$http_x_plex_platform_version;
        proxy_set_header X-Plex-Product \$http_x_plex_product;
        proxy_set_header X-Plex-Token \$http_x_plex_token;
        proxy_set_header X-Plex-Version \$http_x_plex_version;
        proxy_set_header X-Plex-Nocache \$http_x_plex_nocache;
        proxy_set_header X-Plex-Provides \$http_x_plex_provides;
        proxy_set_header X-Plex-Device-Vendor \$http_x_plex_device_vendor;
        proxy_set_header X-Plex-Model \$http_x_plex_model;

        # Range request support for seeking in media files
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }

    location /library/streams/ {
        proxy_pass http://plex_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
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

    sed -i "/^class ${app_name}_meta(${app_name}_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

    cat >>"$profiles_py" <<PYTHON

class ${app_name}_meta(${app_name}_meta):
    baseurl = None
    urloverride = "https://${domain}"
PYTHON

    echo_progress_done "Panel meta updated"
}

_remove_panel_meta() {
    if [ -f "$profiles_py" ]; then
        echo_progress_start "Removing panel meta urloverride"
        sed -i "/^class ${app_name}_meta(${app_name}_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
        echo_progress_done "Panel meta removed"
    fi
}

# ==============================================================================
# Subdomain Install/Revert
# ==============================================================================

_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${PLEX_LE_HOSTNAME:-$domain}"
    local state
    state=$(_get_install_state)

    echo_info "${app_name^} Subdomain Setup"
    echo_info "Domain: $domain"
    [ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
    echo_info "Current state: $state"

    case "$state" in
        "not_installed")
            _install_app
            ;& # fallthrough
        "subfolder" | "unknown")
            _request_certificate "$domain"
            _create_subdomain_vhost "$domain" "$le_hostname"
            _add_panel_meta "$domain"
            _exclude_from_organizr
            _reload_nginx
            _configure_plex_preferences "$domain"
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
    rm -f /etc/nginx/conf.d/upstream-plex.conf

    if [ -f "$backup_dir/${app_name}.conf.bak" ]; then
        cp "$backup_dir/${app_name}.conf.bak" "$subfolder_conf"
        echo_info "Restored subfolder nginx config"
    else
        echo_info "Recreating subfolder config..."
        _create_subfolder_config
    fi

    _remove_panel_meta
    _include_in_organizr
    _reset_plex_preferences

    _reload_nginx
    echo_success "${app_name^} reverted to subfolder mode"
    echo_info "Access at: https://your-server/plex/"
}

# ==============================================================================
# Complete Removal
# ==============================================================================

_remove() {
    local force="$1"
    if [ "$force" != "--force" ] && [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Remove subdomain vhost if exists
    if [ -f "$subdomain_vhost" ]; then
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        rm -f /etc/nginx/conf.d/upstream-plex.conf
        _remove_panel_meta
    fi

    # Remove subfolder config
    rm -f "$subfolder_conf"

    # Remove backup dir
    rm -rf "$backup_dir"

    # Reload nginx
    _reload_nginx 2>/dev/null || true

    # Remove app via box
    echo_info "Removing ${app_name^} via box remove ${app_name}..."
    box remove "$app_name"

    # Remove swizdb entries
    swizdb clear "plex/domain" 2>/dev/null || true

    echo_success "${app_name^} has been removed"
    echo_info "Note: Let's Encrypt certificate was not removed"
    exit 0
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo_info "${app_name^} Setup"

    # Install Plex if needed
    _install_app

    # Create subfolder config if not exists and not on subdomain
    local state
    state=$(_get_install_state)

    if [ "$state" = "unknown" ]; then
        _nginx_subfolder
        state="subfolder"
    fi

    # Ask about subdomain
    if [ "$state" != "subdomain" ]; then
        if ask "Convert Plex to subdomain mode?" N; then
            _install_subdomain
        fi
    else
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
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

_preflight() {
    if [ ! -f /install/.nginx.lock ]; then
        echo_error "nginx is not installed. Please install nginx first."
        exit 1
    fi
}

# ==============================================================================
# Main
# ==============================================================================

_preflight

case "${1:-}" in
    "--subdomain")
        case "${2:-}" in
            "--revert") _revert_subdomain ;;
            "") _install_subdomain ;;
            *) _usage ;;
        esac
        ;;
    "--remove")
        _remove "${2:-}"
        ;;
    "--register-panel")
        if [ ! -f "/install/.${app_lockname}.lock" ]; then
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
