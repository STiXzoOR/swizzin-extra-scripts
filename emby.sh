#!/bin/bash
set -euo pipefail
# emby - Extended Emby installer with subdomain and Premiere support
# STiXzoOR 2025
# Usage: bash emby.sh [--subdomain [--revert]|--premiere [--revert]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

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

app_name="emby"
app_port="8096"
app_lockname="emby"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# Premiere-specific paths
premiere_cert_dir="/etc/nginx/ssl/mb3admin.com"
premiere_vhost="/etc/nginx/sites-available/mb3admin.com"
premiere_enabled="/etc/nginx/sites-enabled/mb3admin.com"
hosts_backup="/etc/hosts.emby-premiere.bak"

# ==============================================================================
# Domain/LE Helper Functions (for subdomain)
# ==============================================================================

# Get domain from swizdb or env
_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "emby/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${EMBY_DOMAIN:-}"
}

# Prompt for domain interactively
_prompt_domain() {
    if [ -n "${EMBY_DOMAIN:-}" ]; then
        echo_info "Using domain from EMBY_DOMAIN: $EMBY_DOMAIN"
        app_domain="$EMBY_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Emby" "[$existing_domain]"
    else
        echo_query "Enter domain for Emby" "(e.g., emby.example.com)"
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
    swizdb set "emby/domain" "$app_domain"
    export EMBY_DOMAIN="$app_domain"
}

# Prompt for Let's Encrypt mode
_prompt_le_mode() {
    if [ -n "${EMBY_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from EMBY_LE_INTERACTIVE: $EMBY_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export EMBY_LE_INTERACTIVE="yes"
    else
        export EMBY_LE_INTERACTIVE="no"
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
        echo_info "Note: ${app_name^} can be re-added to Organizr protection via: bash organizr-subdomain.sh --configure"
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

_is_premiere_enabled() {
    [ "$(swizdb get 'emby/premiere' 2>/dev/null)" = "enabled" ]
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
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    local le_hostname="${EMBY_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${EMBY_LE_INTERACTIVE:-no}"

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
    cat >/etc/nginx/conf.d/upstream-emby.conf <<UPSTREAM
upstream emby_backend {
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
    proxy_redirect off;
    proxy_buffering off;

    # Streaming timeouts (1 hour for long-running streams)
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    ${csp_header}

    location / {
        include snippets/proxy.conf;
        proxy_pass http://emby_backend/;
        proxy_http_version 1.1;

        # WebSocket support with keepalive compatibility
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }

    # WebSocket endpoint for real-time updates
    location /embywebsocket {
        proxy_pass http://emby_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
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
# Subfolder Config
# ==============================================================================

_create_subfolder_config() {
    cat >"$subfolder_conf" <<-'NGX'
		location /emby/ {
		    rewrite /emby/(.*) /$1 break;
		    include /etc/nginx/snippets/proxy.conf;
		    proxy_pass http://127.0.0.1:8096/;
		}
	NGX
}

# ==============================================================================
# Premiere: Get Server ID
# ==============================================================================

_get_server_id() {
    # Try API first (Emby must be running)
    local api_response
    api_response=$(curl -s "http://127.0.0.1:${app_port}/emby/System/Info/Public" 2>/dev/null)
    if [ -n "$api_response" ]; then
        local server_id
        server_id=$(echo "$api_response" | jq -r '.Id // empty' 2>/dev/null)
        if [ -n "$server_id" ]; then
            echo "$server_id"
            return 0
        fi
    fi

    # Fallback: parse system.xml
    local config_file="/var/lib/emby/config/system.xml"
    if [ -f "$config_file" ]; then
        local server_id
        server_id=$(grep -oP '<ServerId>\K[^<]+' "$config_file" 2>/dev/null)
        if [ -n "$server_id" ]; then
            echo "$server_id"
            return 0
        fi
    fi

    return 1
}

# ==============================================================================
# Premiere: Compute MD5 Key
# ==============================================================================

_compute_premiere_key() {
    local server_id="$1"
    # Formula: MD5("MBSupporter" + serverId + "Ae3#fP!wi")
    echo -n "MBSupporter${server_id}Ae3#fP!wi" | md5sum | cut -d' ' -f1
}

# ==============================================================================
# Premiere: Generate Self-Signed Certificate
# ==============================================================================

_generate_premiere_cert() {
    echo_progress_start "Generating self-signed certificate for mb3admin.com"

    mkdir -p "$premiere_cert_dir"

    # Generate self-signed cert (10 years)
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$premiere_cert_dir/key.pem" \
        -out "$premiere_cert_dir/fullchain.pem" \
        -subj "/CN=mb3admin.com" >>"$log" 2>&1

    echo_progress_done "Certificate generated"
}

# ==============================================================================
# Premiere: System CA Trust Management
# ==============================================================================

_install_premiere_ca() {
    echo_progress_start "Adding certificate to system CA trust"

    # Copy cert to system CA directory
    cp "$premiere_cert_dir/fullchain.pem" /usr/local/share/ca-certificates/mb3admin.crt

    # Update CA certificates
    update-ca-certificates >>"$log" 2>&1

    echo_progress_done "Certificate trusted by system"
}

_remove_premiere_ca() {
    if [ -f /usr/local/share/ca-certificates/mb3admin.crt ]; then
        echo_progress_start "Removing certificate from system CA trust"
        rm -f /usr/local/share/ca-certificates/mb3admin.crt
        update-ca-certificates >>"$log" 2>&1
        echo_progress_done "Certificate removed from system trust"
    fi
}

# ==============================================================================
# Premiere: Create nginx Site
# ==============================================================================

_create_premiere_site() {
    local premiere_key="$1"

    echo_progress_start "Creating Premiere nginx site"

    cat >"$premiere_vhost" <<VHOST
server {
    listen 80;
    listen [::]:80;
    server_name mb3admin.com;
    return 301 https://mb3admin.com\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name mb3admin.com;

    ssl_certificate ${premiere_cert_dir}/fullchain.pem;
    ssl_certificate_key ${premiere_cert_dir}/key.pem;
    include snippets/ssl-params.conf;

    location /admin/service/registration/validateDevice {
        default_type application/json;
        return 200 '{"cacheExpirationDays":3650,"message":"Device Valid","resultCode":"GOOD","isPremiere":true}';
    }

    location /admin/service/registration/validate {
        default_type application/json;
        return 200 '{"featId":"","registered":true,"expDate":"2099-01-01","key":"${premiere_key}"}';
    }

    location /admin/service/registration/getStatus {
        default_type application/json;
        return 200 '{"planType":"Lifetime","deviceStatus":0,"subscriptions":[]}';
    }

    location /admin/service/appstore/register {
        default_type application/json;
        return 200 '{"featId":"","registered":true,"expDate":"2099-01-01","key":"${premiere_key}"}';
    }

    location /emby/Plugins/SecurityInfo {
        default_type application/json;
        return 200 '{"SupporterKey":"","IsMBSupporter":true}';
    }

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers * always;
    add_header Access-Control-Allow-Method * always;
    add_header Access-Control-Allow-Credentials true always;
}
VHOST

    [ -L "$premiere_enabled" ] || ln -s "$premiere_vhost" "$premiere_enabled"

    echo_progress_done "Premiere nginx site created"
}

# ==============================================================================
# Premiere: Hosts File Management
# ==============================================================================

_patch_hosts() {
    echo_progress_start "Patching /etc/hosts"

    # Backup first
    cp /etc/hosts "$hosts_backup"

    # Check if already patched
    if grep -q "^# EMBY-PREMIERE-START$" /etc/hosts; then
        echo_info "Hosts already patched, updating..."
        _unpatch_hosts
    fi

    # Add with markers
    cat >>/etc/hosts <<'EOF'
# EMBY-PREMIERE-START
127.0.0.1 mb3admin.com
# EMBY-PREMIERE-END
EOF

    echo_progress_done "Hosts patched"
}

_unpatch_hosts() {
    if grep -q "^# EMBY-PREMIERE-START$" /etc/hosts; then
        sed -i '/^# EMBY-PREMIERE-START$/,/^# EMBY-PREMIERE-END$/d' /etc/hosts
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
    local le_hostname="${EMBY_LE_HOSTNAME:-$domain}"
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
    rm -f /etc/nginx/conf.d/upstream-emby.conf

    if [ -f "$backup_dir/${app_name}.conf.bak" ]; then
        cp "$backup_dir/${app_name}.conf.bak" "$subfolder_conf"
        echo_info "Restored subfolder nginx config"
    else
        echo_info "Recreating subfolder config..."
        _create_subfolder_config
    fi

    _remove_panel_meta
    _include_in_organizr

    _reload_nginx
    echo_success "${app_name^} reverted to subfolder mode"
    echo_info "Access at: https://your-server/${app_name}/"
}

# ==============================================================================
# Premiere Install/Revert
# ==============================================================================

_install_premiere() {
    # Check if Emby is installed
    if [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo_error "${app_name^} is not installed. Install it first."
        exit 1
    fi

    # Check if already enabled
    if _is_premiere_enabled; then
        echo_info "Emby Premiere is already enabled"
        local existing_key
        existing_key=$(swizdb get "emby/premiere_key" 2>/dev/null) || true
        if [ -n "$existing_key" ]; then
            echo_info "Premiere Key: $existing_key"
        fi
        return 0
    fi

    echo_info "Enabling Emby Premiere..."

    # Check for jq
    if ! command -v jq &>/dev/null; then
        echo_info "Installing jq for JSON parsing..."
        apt_install jq
    fi

    # Get server ID
    echo_progress_start "Retrieving Emby Server ID"
    local server_id
    server_id=$(_get_server_id)
    if [ -z "$server_id" ]; then
        echo_error "Could not retrieve Emby Server ID"
        echo_error "Make sure Emby is running or check /var/lib/emby/config/system.xml"
        exit 1
    fi
    echo_progress_done "Server ID: $server_id"

    # Compute key
    echo_progress_start "Computing Premiere key"
    local premiere_key
    premiere_key=$(_compute_premiere_key "$server_id")
    echo_progress_done "Key computed"

    # Generate certificate
    _generate_premiere_cert

    # Add cert to system CA trust (so Emby trusts it)
    _install_premiere_ca

    # Create nginx site
    _create_premiere_site "$premiere_key"

    # Patch hosts
    _patch_hosts

    # Reload nginx
    _reload_nginx

    # Store state
    swizdb set "emby/premiere" "enabled"
    swizdb set "emby/premiere_key" "$premiere_key"
    swizdb set "emby/server_id" "$server_id"

    echo_success "Emby Premiere enabled successfully!"
    echo ""
    echo_info "Server ID: $server_id"
    echo_info "Premiere Key: $premiere_key"
    echo ""
    echo_warn "Save this key for reference."
    echo_info "Restart Emby to activate: systemctl restart emby-server"
}

_revert_premiere() {
    if ! _is_premiere_enabled; then
        echo_info "Emby Premiere is not enabled"
        return 0
    fi

    echo_info "Reverting Emby Premiere bypass..."

    # Remove nginx site
    [ -L "$premiere_enabled" ] && rm -f "$premiere_enabled"
    [ -f "$premiere_vhost" ] && rm -f "$premiere_vhost"

    # Remove hosts patch
    _unpatch_hosts

    # Ask about removing SSL cert
    if ask "Remove self-signed certificate?" N; then
        _remove_premiere_ca
        rm -rf "$premiere_cert_dir"
        echo_info "Certificate removed"
    fi

    # Clear swizdb
    swizdb clear "emby/premiere" 2>/dev/null || true
    swizdb clear "emby/premiere_key" 2>/dev/null || true

    _reload_nginx

    echo_success "Emby Premiere bypass removed"
    echo_info "Restart Emby to deactivate: systemctl restart emby-server"
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

    # Revert premiere if enabled
    if _is_premiere_enabled; then
        _revert_premiere
    fi

    # Revert subdomain if configured
    if [ -f "$subdomain_vhost" ]; then
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        rm -f /etc/nginx/conf.d/upstream-emby.conf
        _remove_panel_meta
    fi

    # Remove subfolder config if exists
    rm -f "$subfolder_conf"

    # Remove backup dir
    rm -rf "$backup_dir"

    # Reload nginx
    _reload_nginx 2>/dev/null || true

    # Remove app via box
    echo_info "Removing ${app_name^} via box remove ${app_name}..."
    box remove "$app_name"

    # Remove all swizdb entries
    swizdb clear "emby/domain" 2>/dev/null || true
    swizdb clear "emby/premiere" 2>/dev/null || true
    swizdb clear "emby/premiere_key" 2>/dev/null || true
    swizdb clear "emby/server_id" 2>/dev/null || true

    echo_success "${app_name^} has been removed"
    echo_info "Note: Let's Encrypt certificate was not removed"
    exit 0
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo_info "${app_name^} Setup"

    # Install Emby if needed
    _install_app

    # Ask about subdomain
    local state
    state=$(_get_install_state)

    if [ "$state" != "subdomain" ]; then
        if ask "Convert Emby to subdomain mode?" N; then
            _install_subdomain
        fi
    else
        echo_info "Subdomain already configured"
    fi

    # Ask about premiere
    if ! _is_premiere_enabled; then
        if ask "Enable Emby Premiere?" N; then
            _install_premiere
        fi
    else
        echo_info "Premiere already enabled"
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
    echo "  --premiere            Enable Emby Premiere"
    echo "  --premiere --revert   Disable Emby Premiere"
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
    "--premiere")
        case "${2:-}" in
            "--revert") _revert_premiere ;;
            "") _install_premiere ;;
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
