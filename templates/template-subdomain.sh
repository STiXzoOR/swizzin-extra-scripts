#!/bin/bash
set -euo pipefail
# ==============================================================================
# EXTENDED INSTALLER TEMPLATE
# ==============================================================================
# Template for extended Swizzin app installers with subdomain support
# Examples: plex.sh, emby.sh, jellyfin.sh
#
# Usage: bash <appname>.sh [--subdomain [--revert]|--register-panel|--remove [--force]]
#
# Interactive mode (no args):
#   - Installs app via box if not installed
#   - Asks about subdomain conversion
#
# Environment bypass (for automation):
#   <APPNAME>_DOMAIN          - Skip domain prompt
#   <APPNAME>_LE_HOSTNAME     - Let's Encrypt hostname (defaults to domain)
#   <APPNAME>_LE_INTERACTIVE  - Set to "yes" for interactive LE (CloudFlare DNS)
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, port, lock name)
# 2. Domain prompt and swizdb key in _prompt_domain() and _get_domain()
# 3. Nginx vhost configuration in _create_subdomain_vhost()
# 4. Subfolder config creation in _create_subfolder_config()
# ==============================================================================

# CUSTOMIZE: Replace "myapp" with your app name throughout this file
# Tip: Use sed 's/myapp/yourapp/g' and 's/Myapp/Yourapp/g' and 's/MYAPP/YOURAPP/g'

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/nginx-utils.sh" 2>/dev/null || true

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
# App Configuration
# ==============================================================================
# CUSTOMIZE: Set app-specific variables

app_name="myapp"
app_port="8080"      # The port the app listens on
app_protocol="http"  # http or https for backend
app_lockname="myapp" # Lock file name (usually same as app_name)

# File paths
backup_dir="/opt/swizzin-extras/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# ==============================================================================
# Domain/LE Helper Functions
# ==============================================================================

# Get domain from swizdb or env
# CUSTOMIZE: Change myapp and MYAPP_DOMAIN to match your app
_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "myapp/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${MYAPP_DOMAIN:-}"
}

# Prompt for domain interactively
# CUSTOMIZE: Change MYAPP_DOMAIN, myapp, and Myapp to match your app
_prompt_domain() {
    if [ -n "${MYAPP_DOMAIN:-}" ]; then
        echo_info "Using domain from MYAPP_DOMAIN: $MYAPP_DOMAIN"
        app_domain="$MYAPP_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Myapp" "[$existing_domain]"
    else
        echo_query "Enter domain for Myapp" "(e.g., myapp.example.com)"
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
    swizdb set "myapp/domain" "$app_domain"
    export MYAPP_DOMAIN="$app_domain"
}

# Prompt for Let's Encrypt mode
# CUSTOMIZE: Change MYAPP_LE_INTERACTIVE to match your app
_prompt_le_mode() {
    if [ -n "${MYAPP_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from MYAPP_LE_INTERACTIVE: $MYAPP_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export MYAPP_LE_INTERACTIVE="yes"
    else
        export MYAPP_LE_INTERACTIVE="no"
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

# CUSTOMIZE: Adjust the subfolder config for your app
_create_subfolder_config() {
    cat >"$subfolder_conf" <<-'NGX'
		location /myapp {
		    return 301 /myapp/;
		}

		location ^~ /myapp/ {
		    include snippets/proxy.conf;
		    proxy_pass http://127.0.0.1:8080/;
		}
	NGX
}

# ==============================================================================
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    # CUSTOMIZE: Update env var name
    local le_hostname="${MYAPP_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${MYAPP_LE_INTERACTIVE:-no}"

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

# CUSTOMIZE: Adjust the vhost configuration for your app
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

    location / {
        include snippets/proxy.conf;
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
    # CUSTOMIZE: Update env var name
    local le_hostname="${MYAPP_LE_HOSTNAME:-$domain}"
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
        _remove_panel_meta
    fi

    rm -f "$subfolder_conf"
    rm -rf "$backup_dir"

    _reload_nginx 2>/dev/null || true

    echo_info "Removing ${app_name^} via box remove ${app_name}..."
    box remove "$app_name"

    # CUSTOMIZE: Change myapp to match your app
    swizdb clear "myapp/domain" 2>/dev/null || true

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
        if ask "Convert ${app_name^} to subdomain mode?" N; then
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
    echo "  --register-panel      Re-register with panel (restore urloverride)"
    echo "  --remove [--force]    Complete removal"
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
    "--remove")
        _remove "$2"
        ;;
    "")
        _interactive
        ;;
    *)
        _usage
        ;;
esac
