#!/bin/bash
set -euo pipefail
# jellyfin - Extended Jellyfin installer with subdomain support
# STiXzoOR 2025
# Usage: bash jellyfin.sh [--subdomain [--revert]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

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

app_name="jellyfin"
app_protocol="https"
app_lockname="jellyfin"

# ==============================================================================
# Port Configuration (avoid conflict with Emby)
# ==============================================================================
# Emby uses: HTTP 8096, HTTPS 8920
# Jellyfin default: HTTP 8096, HTTPS 8920
# If emby installed: HTTP 8097, HTTPS 8921

if [[ -f "/install/.emby.lock" ]]; then
    app_port_http="8097"
    app_port_https="8921"
    echo_info "Emby detected - Jellyfin will use ports $app_port_http (HTTP) / $app_port_https (HTTPS)"
else
    app_port_http="8096"
    app_port_https="8920"
fi
app_port="$app_port_https"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# ==============================================================================
# Domain/LE Helper Functions
# ==============================================================================

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "jellyfin/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${JELLYFIN_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${JELLYFIN_DOMAIN:-}" ]; then
        echo_info "Using domain from JELLYFIN_DOMAIN: $JELLYFIN_DOMAIN"
        app_domain="$JELLYFIN_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Jellyfin" "[$existing_domain]"
    else
        echo_query "Enter domain for Jellyfin" "(e.g., jellyfin.example.com)"
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
    swizdb set "jellyfin/domain" "$app_domain"
    export JELLYFIN_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${JELLYFIN_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from JELLYFIN_LE_INTERACTIVE: $JELLYFIN_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export JELLYFIN_LE_INTERACTIVE="yes"
    else
        export JELLYFIN_LE_INTERACTIVE="no"
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
        # Configure ports if emby is installed
        _configure_ports
    else
        echo_info "${app_name^} already installed"
        # Check if ports need reconfiguration (emby installed after jellyfin)
        if [[ -f "/install/.emby.lock" ]]; then
            _configure_ports
        fi
    fi
}

# ==============================================================================
# Port Configuration (for Emby coexistence)
# ==============================================================================

_configure_ports() {
    # Only configure if we're using non-default ports (emby detected)
    if [[ "$app_port_http" == "8096" ]]; then
        return 0
    fi

    # Ubuntu package installs use /etc/jellyfin/ for config
    local network_xml="/etc/jellyfin/network.xml"

    # Wait for Jellyfin to create its config
    local wait_count=0
    while [[ ! -f "$network_xml" ]] && ((wait_count < 30)); do
        sleep 1
        ((wait_count++))
    done

    if [[ ! -f "$network_xml" ]]; then
        echo_warn "Jellyfin network.xml not found, creating default config..."
        mkdir -p "$(dirname "$network_xml")"
        cat >"$network_xml" <<-XML
			<?xml version="1.0" encoding="utf-8"?>
			<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
			  <BaseUrl />
			  <EnableHttps>true</EnableHttps>
			  <RequireHttps>false</RequireHttps>
			  <InternalHttpPort>${app_port_http}</InternalHttpPort>
			  <InternalHttpsPort>${app_port_https}</InternalHttpsPort>
			  <PublicHttpPort>${app_port_http}</PublicHttpPort>
			  <PublicHttpsPort>${app_port_https}</PublicHttpsPort>
			  <EnableIPv4>true</EnableIPv4>
			  <EnableIPv6>false</EnableIPv6>
			</NetworkConfiguration>
		XML
        chown root:jellyfin "$network_xml"
        chmod 644 "$network_xml"
    else
        echo_progress_start "Configuring Jellyfin ports (HTTP: $app_port_http, HTTPS: $app_port_https)"

        # Migrate old Swizzin element names to Jellyfin 10.9+ names
        # HttpServerPortNumber -> InternalHttpPort
        if grep -q "<HttpServerPortNumber>" "$network_xml"; then
            sed -i "s|<HttpServerPortNumber>[^<]*</HttpServerPortNumber>|<InternalHttpPort>${app_port_http}</InternalHttpPort>|g" "$network_xml"
        fi
        # HttpsPortNumber -> InternalHttpsPort
        if grep -q "<HttpsPortNumber>" "$network_xml"; then
            sed -i "s|<HttpsPortNumber>[^<]*</HttpsPortNumber>|<InternalHttpsPort>${app_port_https}</InternalHttpsPort>|g" "$network_xml"
        fi
        # PublicPort -> PublicHttpPort
        if grep -q "<PublicPort>" "$network_xml"; then
            sed -i "s|<PublicPort>[^<]*</PublicPort>|<PublicHttpPort>${app_port_http}</PublicHttpPort>|g" "$network_xml"
        fi
        # EnableIPV6 -> EnableIPv6 (case fix)
        if grep -q "<EnableIPV6>" "$network_xml"; then
            sed -i "s|<EnableIPV6>[^<]*</EnableIPV6>|<EnableIPv6>false</EnableIPv6>|g" "$network_xml"
        fi
        # EnableIPV4 -> EnableIPv4 (case fix)
        if grep -q "<EnableIPV4>" "$network_xml"; then
            sed -i "s|<EnableIPV4>[^<]*</EnableIPV4>|<EnableIPv4>true</EnableIPv4>|g" "$network_xml"
        fi

        # Update HTTP port (new element names)
        if grep -q "<InternalHttpPort>" "$network_xml"; then
            sed -i "s|<InternalHttpPort>[^<]*</InternalHttpPort>|<InternalHttpPort>${app_port_http}</InternalHttpPort>|g" "$network_xml"
        fi
        if grep -q "<PublicHttpPort>" "$network_xml"; then
            sed -i "s|<PublicHttpPort>[^<]*</PublicHttpPort>|<PublicHttpPort>${app_port_http}</PublicHttpPort>|g" "$network_xml"
        fi

        # Update HTTPS port (new element names)
        if grep -q "<InternalHttpsPort>" "$network_xml"; then
            sed -i "s|<InternalHttpsPort>[^<]*</InternalHttpsPort>|<InternalHttpsPort>${app_port_https}</InternalHttpsPort>|g" "$network_xml"
        fi
        if grep -q "<PublicHttpsPort>" "$network_xml"; then
            sed -i "s|<PublicHttpsPort>[^<]*</PublicHttpsPort>|<PublicHttpsPort>${app_port_https}</PublicHttpsPort>|g" "$network_xml"
        fi

        echo_progress_done "Jellyfin ports configured"
    fi

    # Restart Jellyfin to apply changes
    echo_progress_start "Restarting Jellyfin to apply port changes"
    systemctl restart jellyfin
    sleep 3
    echo_progress_done "Jellyfin restarted"
}

# ==============================================================================
# BaseUrl Management (for subdomain vs subfolder mode)
# ==============================================================================

_clear_baseurl() {
    local network_xml="/etc/jellyfin/network.xml"

    if [[ ! -f "$network_xml" ]]; then
        echo_warn "network.xml not found, skipping BaseUrl clear"
        return 0
    fi

    echo_progress_start "Clearing Jellyfin BaseUrl for subdomain mode"

    # Clear BaseUrl (change <BaseUrl>/jellyfin</BaseUrl> to <BaseUrl />)
    if grep -q "<BaseUrl>" "$network_xml"; then
        sed -i 's|<BaseUrl>[^<]*</BaseUrl>|<BaseUrl />|g' "$network_xml"
    fi

    echo_progress_done "BaseUrl cleared"

    # Restart Jellyfin to apply changes
    systemctl restart jellyfin
    sleep 2
}

_restore_baseurl() {
    local network_xml="/etc/jellyfin/network.xml"

    if [[ ! -f "$network_xml" ]]; then
        echo_warn "network.xml not found, skipping BaseUrl restore"
        return 0
    fi

    echo_progress_start "Restoring Jellyfin BaseUrl for subfolder mode"

    # Restore BaseUrl to /jellyfin
    if grep -q "<BaseUrl />" "$network_xml"; then
        sed -i 's|<BaseUrl />|<BaseUrl>/jellyfin</BaseUrl>|g' "$network_xml"
    elif grep -q "<BaseUrl></BaseUrl>" "$network_xml"; then
        sed -i 's|<BaseUrl></BaseUrl>|<BaseUrl>/jellyfin</BaseUrl>|g' "$network_xml"
    elif grep -q "<BaseUrl>" "$network_xml"; then
        sed -i 's|<BaseUrl>[^<]*</BaseUrl>|<BaseUrl>/jellyfin</BaseUrl>|g' "$network_xml"
    fi

    echo_progress_done "BaseUrl restored"

    # Restart Jellyfin to apply changes
    systemctl restart jellyfin
    sleep 2
}

# ==============================================================================
# Nginx Subfolder Config
# ==============================================================================

_create_subfolder_config() {
    cat >"$subfolder_conf" <<-NGX
		location /jellyfin {
		    proxy_pass https://127.0.0.1:${app_port_https};
		    proxy_pass_request_headers on;
		    proxy_set_header Host \$proxy_host;
		    proxy_http_version 1.1;
		    proxy_set_header X-Real-IP \$remote_addr;
		    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		    proxy_set_header X-Forwarded-Proto \$scheme;
		    proxy_set_header X-Forwarded-Protocol \$scheme;
		    proxy_set_header X-Forwarded-Host \$http_host;
		    proxy_set_header Upgrade \$http_upgrade;
		    proxy_set_header Connection \$http_connection;
		    proxy_set_header X-Forwarded-Ssl on;
		    proxy_redirect off;
		    proxy_buffering off;
		    auth_basic off;
		}
	NGX
}

# ==============================================================================
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    local le_hostname="${JELLYFIN_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${JELLYFIN_LE_INTERACTIVE:-no}"

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
# Subdomain Vhost Creation
# ==============================================================================

_create_subdomain_vhost() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local organizr_domain
    organizr_domain=$(_get_organizr_domain)

    echo_progress_start "Creating subdomain nginx vhost"

    if [ -f "$subfolder_conf" ]; then
        _backup_file "$subfolder_conf"
        rm -f "$subfolder_conf"
    fi

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
    cat >/etc/nginx/conf.d/upstream-jellyfin.conf <<UPSTREAM
upstream jellyfin_backend {
    server 127.0.0.1:${app_port};
    keepalive 32;
}
UPSTREAM

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

    # Streaming timeouts (1 hour for long-running streams)
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    ${csp_header}

    location / {
        proxy_pass http://jellyfin_backend;
        proxy_pass_request_headers on;
        proxy_set_header Host \$proxy_host;
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Protocol \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_redirect off;
        proxy_buffering off;

        if (\$http_user_agent ~ Web0S) {
            add_header Access-Control-Allow-Origin "luna://com.webos.service.config" always;
        }

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }

    location ~ (/jellyfin)?/socket {
        include /etc/nginx/snippets/proxy.conf;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        if (\$http_user_agent ~ Web0S) {
            add_header Access-Control-Allow-Origin "luna://com.webos.service.config" always;
        }
        proxy_pass ${app_protocol}://127.0.0.1:${app_port};
    }

    # Restrict access to /metrics
    # https://jellyfin.org/docs/general/networking/monitoring/#prometheus-metrics
    location /metrics {
        allow 192.168.0.0/16;
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 127.0.0.0/8;

        deny all;

        include /etc/nginx/snippets/proxy.conf;
        proxy_pass ${app_protocol}://127.0.0.1:${app_port};
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
    local le_hostname="${JELLYFIN_LE_HOSTNAME:-$domain}"
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
            _clear_baseurl
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
    rm -f /etc/nginx/conf.d/upstream-jellyfin.conf

    if [ -f "$backup_dir/${app_name}.conf.bak" ]; then
        cp "$backup_dir/${app_name}.conf.bak" "$subfolder_conf"
        echo_info "Restored subfolder nginx config"
    else
        echo_info "Recreating subfolder config..."
        _create_subfolder_config
    fi

    _restore_baseurl
    _remove_panel_meta
    _include_in_organizr

    _reload_nginx
    echo_success "${app_name^} reverted to subfolder mode"
    echo_info "Access at: https://your-server/${app_name}/"
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

    if [ -f "$subdomain_vhost" ]; then
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        rm -f /etc/nginx/conf.d/upstream-jellyfin.conf
        _remove_panel_meta
    fi

    rm -f "$subfolder_conf"
    rm -rf "$backup_dir"

    _reload_nginx 2>/dev/null || true

    echo_info "Removing ${app_name^} via box remove ${app_name}..."
    box remove "$app_name"

    swizdb clear "jellyfin/domain" 2>/dev/null || true

    echo_success "${app_name^} has been removed"
    echo_info "Note: Let's Encrypt certificate was not removed"
    exit 0
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo_info "${app_name^} Setup"

    _install_app

    local state
    state=$(_get_install_state)

    if [ "$state" != "subdomain" ]; then
        if ask "Convert Jellyfin to subdomain mode?" N; then
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
        _remove "$2"
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
