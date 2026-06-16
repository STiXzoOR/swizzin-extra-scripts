#!/bin/bash
set -euo pipefail
# panel - Extended Panel installer with subdomain support
# STiXzoOR 2026
# Usage: bash panel.sh [--subdomain [--revert]|--remove [--force]]

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

app_name="panel"
app_lockname="panel"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
default_site="/etc/nginx/sites-enabled/default"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# ==============================================================================
# Domain/LE Helper Functions
# ==============================================================================

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "panel/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${PANEL_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        echo_info "Using domain from PANEL_DOMAIN: $PANEL_DOMAIN"
        app_domain="$PANEL_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Panel" "[$existing_domain]"
    else
        echo_query "Enter domain for Panel" "(e.g., panel.example.com or example.com)"
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
    swizdb set "panel/domain" "$app_domain"
    export PANEL_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${PANEL_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from PANEL_LE_INTERACTIVE: $PANEL_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export PANEL_LE_INTERACTIVE="yes"
    else
        export PANEL_LE_INTERACTIVE="no"
    fi
}

# ==============================================================================
# Organizr Integration
# ==============================================================================

_is_organizr_subdomain() {
    # Check if Organizr is installed AND in subdomain mode
    if [ -f "/install/.organizr.lock" ] && [ -f "/etc/nginx/sites-enabled/organizr" ]; then
        return 0
    fi
    return 1
}

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
        return
    fi

    # Check if default site has a specific domain (not catch-all)
    if [ -f "$default_site" ]; then
        # Look for server_name in the SSL block that isn't "_"
        local ssl_server_name
        ssl_server_name=$(grep -A 20 "listen 443" "$default_site" | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';')
        if [ -n "$ssl_server_name" ] && [ "$ssl_server_name" != "_" ]; then
            echo "subdomain"
            return
        fi
    fi

    echo "subfolder"
}

_get_current_domain() {
    # Extract domain from default site SSL block
    if [ -f "$default_site" ]; then
        local ssl_server_name
        ssl_server_name=$(grep -A 20 "listen 443" "$default_site" | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';')
        if [ -n "$ssl_server_name" ] && [ "$ssl_server_name" != "_" ]; then
            echo "$ssl_server_name"
        fi
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
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    local le_hostname="${PANEL_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${PANEL_LE_INTERACTIVE:-no}"

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

_backup_default_site() {
    _ensure_backup_dir
    if [ -f "$default_site" ] && [ ! -f "$backup_dir/default.bak" ]; then
        cp "$default_site" "$backup_dir/default.bak"
        echo_info "Backed up default site config"
    fi
}

# ==============================================================================
# Default Site Modification
# ==============================================================================

_update_default_site() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"

    echo_progress_start "Updating default site with domain and SSL certificate"

    _backup_default_site

    # Use awk to precisely update only the SSL (port 443) server block
    # This handles the server_name change only in the correct block
    awk -v domain="$domain" -v cert_dir="$cert_dir" '
	BEGIN { in_ssl_block = 0 }
	/listen 443/ { in_ssl_block = 1 }
	/^}/ { if (in_ssl_block) in_ssl_block = 0 }
	{
		if (in_ssl_block && /server_name/) {
			gsub(/server_name [^;]+;/, "server_name " domain ";")
		}
		if (in_ssl_block && /ssl_certificate[^_]/) {
			gsub(/ssl_certificate [^;]+;/, "ssl_certificate " cert_dir "/fullchain.pem;")
		}
		if (in_ssl_block && /ssl_certificate_key/) {
			gsub(/ssl_certificate_key [^;]+;/, "ssl_certificate_key " cert_dir "/key.pem;")
		}
		print
	}
	' "$default_site" >"${default_site}.tmp" && mv "${default_site}.tmp" "$default_site"

    echo_progress_done "Default site updated"
}

_restore_default_site() {
    if [ -f "$backup_dir/default.bak" ]; then
        echo_progress_start "Restoring original default site config"
        cp "$backup_dir/default.bak" "$default_site"
        echo_progress_done "Default site restored"
    else
        echo_warn "No backup found, manually restoring default values"
        # Restore to snake-oil certs and catch-all server_name
        sed -i "s|server_name [^;]*;|server_name _;|" "$default_site"
        sed -i "s|ssl_certificate /etc/nginx/ssl/[^/]*/fullchain.pem;|ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;|" "$default_site"
        sed -i "s|ssl_certificate_key /etc/nginx/ssl/[^/]*/key.pem;|ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;|" "$default_site"
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
    local le_hostname="${PANEL_LE_HOSTNAME:-$domain}"
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
            _update_default_site "$domain" "$le_hostname"

            # Organizr exclusion prompt (only if Organizr is in subdomain mode)
            if _is_organizr_subdomain; then
                if ask "Exclude Panel from Organizr SSO protection?" Y; then
                    _exclude_from_organizr
                fi
            fi

            _reload_nginx
            echo_success "${app_name^} converted to subdomain mode"
            echo_info "Access at: https://$domain"
            ;;
        "subdomain")
            local current_domain
            current_domain=$(_get_current_domain)
            echo_info "Already in subdomain mode (domain: $current_domain)"
            echo_info "To change domain, revert first: bash panel.sh --subdomain --revert"
            ;;
    esac
}

_revert_subdomain() {
    local state
    state=$(_get_install_state)

    if [ "$state" != "subdomain" ]; then
        echo_error "Panel is not in subdomain mode"
        exit 1
    fi

    echo_info "Reverting ${app_name^} to default mode..."

    _restore_default_site
    _include_in_organizr

    swizdb clear "panel/domain" 2>/dev/null || true

    _reload_nginx
    echo_success "${app_name^} reverted to default mode"
    echo_info "Access at: https://your-server-ip/"
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

    local state
    state=$(_get_install_state)

    # Restore default site if in subdomain mode
    if [ "$state" = "subdomain" ]; then
        _restore_default_site
    fi

    rm -rf "$backup_dir"

    _reload_nginx 2>/dev/null || true

    echo_info "Removing ${app_name^} via box remove ${app_name}..."
    box remove "$app_name"

    swizdb clear "panel/domain" 2>/dev/null || true

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
        if ask "Set up subdomain for Panel?" N; then
            _install_subdomain
        fi
    else
        local current_domain
        current_domain=$(_get_current_domain)
        echo_info "Subdomain already configured (domain: $current_domain)"
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
    echo "  --subdomain --revert  Revert to default mode"
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

    if [ ! -f "$default_site" ]; then
        echo_error "Default nginx site not found at $default_site"
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
    "")
        _interactive
        ;;
    *)
        _usage
        ;;
esac
