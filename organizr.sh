#!/bin/bash
set -euo pipefail
# organizr - Extended Organizr installer with subdomain and SSO support
# STiXzoOR 2025
# Usage: bash organizr.sh [--subdomain [--revert]|--configure|--migrate|--register-panel|--remove]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

#shellcheck source=sources/functions/php
. /etc/swizzin/sources/functions/php

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

config_dir="/opt/swizzin-extras"
config_file="$config_dir/organizr-auth.conf"
backup_dir="$config_dir/organizr-backups"
auth_snippet="/etc/nginx/snippets/organizr-auth.conf"
subfolder_conf="/etc/nginx/apps/organizr.conf"
subdomain_vhost="/etc/nginx/sites-available/organizr"
subdomain_enabled="/etc/nginx/sites-enabled/organizr"
profiles_py="/opt/swizzin/core/custom/profiles.py"

# Apps that MUST always have auth_request - they can expose API keys or
# compromise the *arr stack if accessed without authentication.
# These cannot be deselected in the whiptail dialog.
FORCED_AUTH_APPS=("huntarr" "newtarr" "cleanuparr" "prowlarr")

_is_forced_app() {
    local app="$1"
    for forced in "${FORCED_AUTH_APPS[@]}"; do
        [[ "$forced" == "$app" ]] && return 0
    done
    return 1
}

# Get domain from swizdb, config file, or env
_get_domain() {
    # Check swizdb first
    local swizdb_domain
    swizdb_domain=$(swizdb get "organizr/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi

    # Check config file
    if [ -f "$config_file" ] && grep -q "^ORGANIZR_DOMAIN=" "$config_file"; then
        grep "^ORGANIZR_DOMAIN=" "$config_file" | cut -d'"' -f2
        return
    fi

    # Fall back to env
    echo "${ORGANIZR_DOMAIN:-}"
}

# Prompt for domain interactively
_prompt_domain() {
    # Check environment variable first (bypass)
    if [ -n "${ORGANIZR_DOMAIN:-}" ]; then
        echo_info "Using domain from ORGANIZR_DOMAIN: $ORGANIZR_DOMAIN"
        app_domain="$ORGANIZR_DOMAIN"
        return
    fi

    # Get existing domain as default
    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Organizr" "[$existing_domain]"
    else
        echo_query "Enter domain for Organizr" "(e.g., organizr.example.com)"
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
        # Basic validation
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

    # Store in swizdb
    swizdb set "organizr/domain" "$app_domain"

    # Export for other functions
    export ORGANIZR_DOMAIN="$app_domain"
}

# Prompt for Let's Encrypt mode
_prompt_le_mode() {
    # Check environment variable first (bypass)
    if [ -n "${ORGANIZR_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from ORGANIZR_LE_INTERACTIVE: $ORGANIZR_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export ORGANIZR_LE_INTERACTIVE="yes"
    else
        export ORGANIZR_LE_INTERACTIVE="no"
    fi
}

# Pre-flight checks
_preflight() {
    # Check nginx
    if [ ! -f /install/.nginx.lock ]; then
        echo_error "nginx is not installed. Please install nginx first."
        exit 1
    fi

    # For subdomain install/configure, prompt for domain and LE mode
    # Skip for interactive (handles its own prompting), revert, and remove
    case "${1:-}" in
        "--subdomain" | "--configure")
            _prompt_domain
            _prompt_le_mode
            ;;
    esac
}

# Check current state of Organizr installation
_get_install_state() {
    if [ ! -f /install/.organizr.lock ]; then
        echo "not_installed"
    elif [ -f "$subdomain_vhost" ]; then
        echo "subdomain"
    elif [ -f "$subfolder_conf" ]; then
        echo "subfolder"
    else
        echo "unknown"
    fi
}

# Install Organizr via box if not installed
_install_organizr() {
    if [ ! -f /install/.organizr.lock ]; then
        echo_info "Installing Organizr via box install organizr..."
        box install organizr || {
            echo_error "Failed to install Organizr"
            exit 1
        }
    else
        echo_info "Organizr already installed"
    fi
}

# Request Let's Encrypt certificate
_request_certificate() {
    local domain="$1"
    # Allow custom LE hostname (e.g., for wildcard certs)
    local le_hostname="${ORGANIZR_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${ORGANIZR_LE_INTERACTIVE:-no}"

    if [ -d "$cert_dir" ]; then
        echo_info "Let's Encrypt certificate already exists for $le_hostname"
        return 0
    fi

    echo_info "Requesting Let's Encrypt certificate for $le_hostname"

    if [ "$le_interactive" = "yes" ]; then
        # Interactive mode - let user answer prompts (e.g., for CloudFlare DNS)
        echo_info "Running Let's Encrypt in interactive mode..."
        LE_HOSTNAME="$le_hostname" box install letsencrypt </dev/tty
        local result=$?
    else
        # Non-interactive mode
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

# Create backup directory
_ensure_backup_dir() {
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
    fi
}

# Backup a file
_backup_file() {
    local src="$1"
    local name
    name=$(basename "$src")
    _ensure_backup_dir
    if [ -f "$src" ]; then
        cp "$src" "$backup_dir/${name}.bak"
    fi
}

# Create subdomain nginx vhost
_create_subdomain_vhost() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local phpv
    phpv=$(php_service_version)
    local cert_dir="/etc/nginx/ssl/$le_hostname"

    echo_progress_start "Creating subdomain nginx vhost"

    # Backup and remove subfolder config
    if [ -f "$subfolder_conf" ]; then
        _backup_file "$subfolder_conf"
        rm -f "$subfolder_conf"
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

    # Organizr SSO auth endpoint (internal rewrite to /api/v2)
    location ~ /organizr-auth/auth-([0-9]+) {
        internal;
        rewrite ^/organizr-auth/auth-(.*)$ /api/v2/auth?group=\$1;
    }

    # Redirect 401 to Organizr login
    error_page 401 = @organizr_login;
    location @organizr_login {
        return 302 https://$domain/?error=\$status&return=\$scheme://\$http_host\$request_uri;
    }

    # Include app configs (excluding panel which has conflicting location /)
    include /etc/nginx/snippets/organizr-apps.conf;

    root /srv/organizr;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${phpv}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffers 32 32k;
        fastcgi_buffer_size 32k;
    }

    location /api/v2 {
        try_files \$uri /api/v2/index.php\$is_args\$args;
    }

    location ~ /\.ht {
        deny all;
    }
}
VHOST

    # Enable site
    if [ ! -L "$subdomain_enabled" ]; then
        ln -s "$subdomain_vhost" "$subdomain_enabled"
    fi

    echo_progress_done "Subdomain vhost created"
}

# Create organizr auth snippet (only the internal auth location)
_create_auth_snippet() {
    echo_progress_start "Creating Organizr auth snippet"

    # Note: error_page and @organizr_login are in the subdomain vhost at server level
    cat >"$auth_snippet" <<'SNIPPET'
# Organizr SSO Authentication
# Include this in location blocks and add: auth_request /organizr-auth/auth-0;
# The error_page 401 and @organizr_login are defined in the organizr vhost
SNIPPET

    echo_progress_done "Auth snippet created"
}

# Generate apps include file (only includes protected apps)
_generate_apps_include() {
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"

    echo_progress_start "Generating apps include file"

    # Start fresh
    cat >"$apps_include" <<'HEADER'
# Auto-generated by organizr.sh
# Only apps protected by Organizr SSO are included here
HEADER

    # Only include apps that are protected (in config file)
    local protected_apps
    protected_apps=$(_get_protected_apps)

    for line in $protected_apps; do
        local app="${line%%:*}"
        local conf="/etc/nginx/apps/${app}.conf"
        [ -f "$conf" ] || continue
        echo "include $conf;" >>"$apps_include"
    done

    echo_progress_done "Apps include file generated"
}

# Add app to organizr-apps.conf
_add_to_apps_include() {
    local app="$1"
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"
    local conf="/etc/nginx/apps/${app}.conf"

    [ -f "$apps_include" ] || return
    [ -f "$conf" ] || return

    # Check if already included
    if grep -q "include $conf;" "$apps_include" 2>/dev/null; then
        return
    fi

    echo "include $conf;" >>"$apps_include"
}

# Remove app from organizr-apps.conf
_remove_from_apps_include() {
    local app="$1"
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"
    local conf="/etc/nginx/apps/${app}.conf"

    [ -f "$apps_include" ] || return

    # Remove the include line
    sed -i "\|include $conf;|d" "$apps_include"
}

# Add panel meta urloverride
_add_panel_meta() {
    local domain="$1"

    echo_progress_start "Adding panel meta urloverride"

    # Ensure profiles.py exists
    mkdir -p "$(dirname "$profiles_py")"
    touch "$profiles_py"

    # Remove existing override if present
    sed -i "/^class organizr_meta(organizr_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

    # Add new override
    cat >>"$profiles_py" <<PYTHON

class organizr_meta(organizr_meta):
    baseurl = None
    urloverride = "https://${domain}"
PYTHON

    echo_progress_done "Panel meta updated"
}

# Remove panel meta urloverride
_remove_panel_meta() {
    if [ -f "$profiles_py" ]; then
        echo_progress_start "Removing panel meta urloverride"
        sed -i "/^class organizr_meta(organizr_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
        # Clean up empty lines at end of file
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
        echo_progress_done "Panel meta removed"
    fi
}

# Get list of installed apps with nginx configs
_get_available_apps() {
    local apps=()
    for conf in /etc/nginx/apps/*.conf; do
        [ -f "$conf" ] || continue
        local name
        name=$(basename "$conf" .conf)
        # Skip organizr itself and some special configs
        case "$name" in
            organizr | default | ssl) continue ;;
        esac
        apps+=("$name")
    done
    echo "${apps[@]}"
}

# Interactive app selection using whiptail
_select_apps() {
    local available_apps
    read -ra available_apps <<<"$(_get_available_apps)"

    if [ ${#available_apps[@]} -eq 0 ]; then
        echo_warn "No apps found to protect"
        return
    fi

    # Build whiptail options
    local options=()
    for app in "${available_apps[@]}"; do
        if _is_forced_app "$app"; then
            options+=("$app" "[FORCED]" "ON")
        elif [ -f "$config_file" ] && grep -q "^${app}:" "$config_file"; then
            options+=("$app" "" "ON")
        else
            options+=("$app" "" "OFF")
        fi
    done

    # Show selection dialog
    local selected
    selected=$(whiptail --title "Organizr SSO Setup" \
        --checklist "Select apps to protect with Organizr authentication:\n(Space to toggle, Enter to confirm)" \
        20 60 10 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) || {
        echo_info "App selection cancelled"
        return 1
    }

    # Parse selected apps (whiptail returns "app1" "app2" format)
    selected=$(echo "$selected" | tr -d '"')

    # Re-inject forced apps that the user may have deselected
    for app in "${FORCED_AUTH_APPS[@]}"; do
        if [[ -f "/etc/nginx/apps/${app}.conf" ]] && ! echo " $selected " | grep -q " $app "; then
            selected="$selected $app"
            echo_warn "$app is a forced-auth app and cannot be deselected"
        fi
    done

    # Update config file
    _update_config "$selected"
}

# Update config file with selected apps
_update_config() {
    local selected_apps="$1"
    local domain
    domain=$(_get_domain)

    mkdir -p "$config_dir"

    # Write config header
    cat >"$config_file" <<CONFIG
# Organizr SSO Configuration
# Format: app_name:auth_level
# Auth levels: 0=Admin, 1=Co-Admin, 2=Super User, 3=Power User, 4=User, 998=Logged In
# Re-run 'bash organizr.sh --configure' after editing

ORGANIZR_DOMAIN="$domain"

# Protected apps (default: 0 = Admin only)
CONFIG

    # Add selected apps
    for app in $selected_apps; do
        # Check if app has existing auth level in old config
        local level=0
        if [ -f "$config_file.tmp" ] && grep -q "^${app}:" "$config_file.tmp"; then
            level=$(grep "^${app}:" "$config_file.tmp" | cut -d: -f2)
        fi
        echo "${app}:${level}" >>"$config_file"
    done

    echo_info "Config saved to $config_file"
}

# Get protected apps from config
_get_protected_apps() {
    if [ ! -f "$config_file" ]; then
        return
    fi
    grep -E "^[a-zA-Z0-9_-]+:[0-9]+$" "$config_file" || true
}

# Modify app nginx config to use Organizr auth
_protect_app() {
    local app="$1"
    local auth_level="$2"
    local conf="/etc/nginx/apps/${app}.conf"

    if [ ! -f "$conf" ]; then
        echo_warn "Config not found for $app, skipping"
        return
    fi

    # Skip if already has auth_request (but for forced apps, ensure ALL blocks are protected)
    if grep -q "auth_request /organizr-auth" "$conf"; then
        echo_info "$app already protected, updating auth level"
        sed -i "s|auth_request /organizr-auth/auth-[0-9]*;|auth_request /organizr-auth/auth-${auth_level};|g" "$conf"

        # For forced apps, also replace any "auth_request off;" and ensure
        # ALL proxy_pass blocks have auth_request (not just the first)
        if _is_forced_app "$app"; then
            sed -i "s|auth_request off;|auth_request /organizr-auth/auth-${auth_level};|g" "$conf"
            # Check for proxy_pass blocks missing auth_request
            local temp_conf
            temp_conf=$(mktemp)
            awk -v level="$auth_level" '
            BEGIN { brace_depth = 0; buffer = ""; has_proxy = 0; has_auth = 0 }
            /location.*\{/ && brace_depth == 0 {
                brace_depth = 1; has_proxy = 0; has_auth = 0; buffer = $0 "\n"; next
            }
            brace_depth > 0 {
                buffer = buffer $0 "\n"
                if (/\{/) brace_depth++
                if (/\}/) brace_depth--
                if (/proxy_pass/) has_proxy = 1
                if (/auth_request/) has_auth = 1
                if (brace_depth == 0) {
                    if (has_proxy && !has_auth) {
                        n = split(buffer, lines, "\n")
                        for (i = 1; i <= n; i++) {
                            if (lines[i] ~ /location.*\{/) {
                                print lines[i]
                                print "    auth_request /organizr-auth/auth-" level ";"
                            } else if (lines[i] != "") {
                                print lines[i]
                            }
                        }
                    } else {
                        printf "%s", buffer
                    }
                    buffer = ""
                }
                next
            }
            { print }
            ' "$conf" >"$temp_conf"
            mv "$temp_conf" "$conf"
        fi

        # Ensure it's in apps include
        _add_to_apps_include "$app"
        return
    fi

    # Backup original
    _backup_file "$conf"

    echo_progress_start "Protecting $app with Organizr auth"

    # Comment out existing auth_basic
    sed -i 's/^\([[:space:]]*auth_basic\)/#\1/g' "$conf"
    sed -i 's/^\([[:space:]]*auth_basic_user_file\)/#\1/g' "$conf"

    # For forced apps, also replace any existing "auth_request off;"
    if _is_forced_app "$app"; then
        sed -i "s|auth_request off;|auth_request /organizr-auth/auth-${auth_level};|g" "$conf"
    fi

    # Find location blocks with proxy_pass (skip return 301 redirects)
    # For forced apps (protect_all=1), add auth_request to ALL proxy blocks
    local protect_all=0
    _is_forced_app "$app" && protect_all=1
    local temp_conf
    temp_conf=$(mktemp)

    awk -v level="$auth_level" -v protect_all="$protect_all" '
	BEGIN { brace_depth = 0; buffer = ""; has_proxy = 0; added_global = 0 }

	# Track brace depth for nested location blocks
	/location.*\{/ && brace_depth == 0 {
		# Start of top-level location block
		brace_depth = 1
		has_proxy = 0
		buffer = $0 "\n"
		next
	}

	brace_depth > 0 {
		buffer = buffer $0 "\n"

		# Count braces to handle nested blocks
		if (/\{/) brace_depth++
		if (/\}/) brace_depth--

		# Check if this block has proxy_pass (real content, not just redirect)
		if (/proxy_pass/) {
			has_proxy = 1
		}

		# End of top-level location block (all braces closed)
		if (brace_depth == 0) {
			# For forced apps (protect_all), add auth_request to every proxy block
			# For normal apps, only add to the first proxy block
			if (has_proxy && (protect_all || !added_global)) {
				# Insert auth_request after the opening brace line
				n = split(buffer, lines, "\n")
				for (i = 1; i <= n; i++) {
					if (lines[i] ~ /location.*\{/ && (protect_all || !added_global)) {
						print lines[i]
						print "        auth_request /organizr-auth/auth-" level ";"
						added_global = 1
					} else if (lines[i] != "") {
						print lines[i]
					}
				}
			} else {
				# Print buffer without modification
				printf "%s", buffer
			}
			buffer = ""
		}
		next
	}

	{ print }
	' "$conf" >"$temp_conf"

    mv "$temp_conf" "$conf"

    # Add to organizr-apps.conf so it's accessible via Organizr subdomain
    _add_to_apps_include "$app"

    echo_progress_done "$app protected"
}

# Remove Organizr auth from app config
_unprotect_app() {
    local app="$1"
    local conf="/etc/nginx/apps/${app}.conf"

    if [ ! -f "$conf" ]; then
        return
    fi

    # Forced apps revert to basic auth instead of losing all authentication
    if _is_forced_app "$app"; then
        echo_info "Reverting $app to basic auth (forced-auth app)"
        # Remove auth_request lines
        sed -i '/auth_request \/organizr-auth\/auth-[0-9]*;/d' "$conf"
        sed -i '/auth_request off;/d' "$conf"
        # Uncomment auth_basic (restores installer defaults)
        sed -i 's/^#\([[:space:]]*auth_basic\)/\1/g' "$conf"
        sed -i 's/^#\([[:space:]]*auth_basic_user_file\)/\1/g' "$conf"
        _remove_from_apps_include "$app"
        echo_progress_done "$app reverted to basic auth"
        return
    fi

    echo_progress_start "Removing Organizr auth from $app"

    # Remove auth_request line
    sed -i '/auth_request \/organizr-auth\/auth-[0-9]*;/d' "$conf"
    # Also remove legacy include line if present from older installs
    sed -i '/include \/etc\/nginx\/snippets\/organizr-auth.conf;/d' "$conf"

    # Uncomment auth_basic
    sed -i 's/^#\([[:space:]]*auth_basic\)/\1/g' "$conf"
    sed -i 's/^#\([[:space:]]*auth_basic_user_file\)/\1/g' "$conf"

    # Remove from organizr-apps.conf so it's no longer accessible via Organizr subdomain
    _remove_from_apps_include "$app"

    echo_progress_done "$app auth removed"
}

# Migrate auth_request from redirect blocks to proxy blocks
_migrate_auth_placement() {
    local app="$1"
    local conf="/etc/nginx/apps/${app}.conf"

    [ -f "$conf" ] || return 0

    # Check if auth_request exists in this config
    grep -q "auth_request /organizr-auth" "$conf" || return 0

    # Check if auth_request is in a redirect block (misplaced)
    # Look for pattern: location block with both auth_request and return 301
    if awk '
		/location.*\{/ { in_loc=1; has_auth=0; has_redirect=0; block="" }
		in_loc { block = block $0 "\n" }
		in_loc && /auth_request/ { has_auth=1 }
		in_loc && /return 301/ { has_redirect=1 }
		in_loc && /^\s*\}/ {
			in_loc=0
			if (has_auth && has_redirect) { exit 0 }  # Found misplaced auth
		}
		END { exit 1 }
	' "$conf"; then
        echo_progress_start "Migrating $app auth placement"

        # Extract the auth level from existing config
        local auth_level
        auth_level=$(grep -oP 'auth_request /organizr-auth/auth-\K[0-9]+' "$conf" | head -1)
        [ -z "$auth_level" ] && auth_level=0

        # Remove all auth_request lines first
        sed -i '/auth_request \/organizr-auth\/auth-[0-9]*;/d' "$conf"

        # Re-apply auth correctly using brace depth for nested locations
        local temp_conf
        temp_conf=$(mktemp)

        awk -v level="$auth_level" '
		BEGIN { brace_depth = 0; buffer = ""; has_proxy = 0; added_global = 0 }

		/location.*\{/ && brace_depth == 0 {
			brace_depth = 1
			has_proxy = 0
			buffer = $0 "\n"
			next
		}

		brace_depth > 0 {
			buffer = buffer $0 "\n"
			if (/\{/) brace_depth++
			if (/\}/) brace_depth--
			if (/proxy_pass/) { has_proxy = 1 }
			if (brace_depth == 0) {
				if (has_proxy && !added_global) {
					n = split(buffer, lines, "\n")
					for (i = 1; i <= n; i++) {
						if (lines[i] ~ /location.*\{/ && !added_global) {
							print lines[i]
							print "        auth_request /organizr-auth/auth-" level ";"
							added_global = 1
						} else if (lines[i] != "") {
							print lines[i]
						}
					}
				} else {
					printf "%s", buffer
				}
				buffer = ""
			}
			next
		}

		{ print }
		' "$conf" >"$temp_conf"

        mv "$temp_conf" "$conf"
        echo_progress_done "$app migrated"
        return 0
    fi

    return 0
}

# Migrate all protected apps
_migrate_all_apps() {
    local migrated=0

    for conf in /etc/nginx/apps/*.conf; do
        [ -f "$conf" ] || continue
        local app
        app=$(basename "$conf" .conf)
        if _migrate_auth_placement "$app"; then
            ((migrated++)) || true
        fi
    done

    if [ "$migrated" -gt 0 ]; then
        _reload_nginx
        echo_info "Migration complete"
    fi
}

# Apply protection to all configured apps
_apply_protection() {
    local protected_apps
    protected_apps=$(_get_protected_apps)

    if [ -z "$protected_apps" ]; then
        echo_info "No apps configured for protection"
        return
    fi

    # First, migrate any misconfigured apps
    echo "$protected_apps" | while IFS=: read -r app level; do
        _migrate_auth_placement "$app"
    done

    echo "$protected_apps" | while IFS=: read -r app level; do
        _protect_app "$app" "$level"
    done
}

# Remove protection from all apps
_remove_all_protection() {
    local available_apps
    read -ra available_apps <<<"$(_get_available_apps)"

    for app in "${available_apps[@]}"; do
        _unprotect_app "$app"
    done
}

# Main install/convert flow
_install() {
    local domain
    domain=$(_get_domain)
    local le_hostname="${ORGANIZR_LE_HOSTNAME:-$domain}"
    local state
    state=$(_get_install_state)

    echo_info "Organizr Subdomain Setup"
    echo_info "Domain: $domain"
    [ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
    echo_info "Current state: $state"

    case "$state" in
        "not_installed")
            _install_organizr
            ;& # fallthrough
        "subfolder")
            _request_certificate "$domain"
            _create_subdomain_vhost "$domain" "$le_hostname"
            _create_auth_snippet
            _generate_apps_include
            _add_panel_meta "$domain"
            _select_apps
            _apply_protection
            _reload_nginx
            reload_php_fpm
            echo_success "Organizr converted to subdomain mode"
            echo_info "Access at: https://$domain"
            echo_warn "Note: Swizzin's automated Organizr setup may have failed."
            echo_warn "If Organizr shows the setup wizard, complete it manually at https://$domain"
            ;;
        "subdomain")
            echo_info "Already in subdomain mode, running configure..."
            _configure
            ;;
        *)
            echo_error "Unknown installation state"
            exit 1
            ;;
    esac
}

# Configure mode - just update app selection
_configure() {
    local domain
    domain=$(_get_domain)

    if [ -z "$domain" ]; then
        echo_error "Organizr is not configured in subdomain mode"
        exit 1
    fi

    # Save current config for reference
    if [ -f "$config_file" ]; then
        cp "$config_file" "$config_file.tmp"
    fi

    _select_apps

    # Remove protection from apps no longer in list
    local available_apps
    read -ra available_apps <<<"$(_get_available_apps)"
    local protected_apps
    protected_apps=$(_get_protected_apps)

    for app in "${available_apps[@]}"; do
        if ! echo "$protected_apps" | grep -q "^${app}:"; then
            _unprotect_app "$app"
        fi
    done

    # Apply protection to configured apps
    _apply_protection

    # Cleanup temp file
    rm -f "$config_file.tmp"

    _reload_nginx
    echo_success "Organizr SSO configuration updated"
}

# Revert to subfolder mode
_revert() {
    echo_info "Reverting Organizr to subfolder mode..."

    # Remove protection from all apps
    _remove_all_protection

    # Remove subdomain vhost
    if [ -L "$subdomain_enabled" ]; then
        rm -f "$subdomain_enabled"
    fi
    if [ -f "$subdomain_vhost" ]; then
        rm -f "$subdomain_vhost"
    fi

    # Restore subfolder config
    if [ -f "$backup_dir/organizr.conf.bak" ]; then
        cp "$backup_dir/organizr.conf.bak" "$subfolder_conf"
        echo_info "Restored subfolder nginx config"
    else
        # Recreate using swizzin's script
        echo_info "Recreating subfolder config..."
        bash /usr/local/bin/swizzin/nginx/organizr.sh
    fi

    # Remove panel meta override
    _remove_panel_meta

    # Keep auth snippet and config for future use
    echo_info "Config preserved at $config_file for future re-enable"

    _reload_nginx
    echo_success "Organizr reverted to subfolder mode"
    echo_info "Access at: https://your-server/organizr/"
}

# Complete removal
_remove() {
    echo_info "Removing Organizr subdomain setup..."

    # Ask about purging
    if ask "Would you like to completely remove Organizr?" N; then
        # Revert first
        _revert

        # Remove organizr via box
        echo_info "Removing Organizr via box remove organizr..."
        box remove organizr

        # Remove our files
        rm -f "$auth_snippet"
        rm -f "/etc/nginx/snippets/organizr-apps.conf"
        rm -f "$config_file"
        rm -rf "$backup_dir"

        # Remove swizdb entry
        swizdb clear "organizr/domain" 2>/dev/null || true

        echo_success "Organizr completely removed"
        echo_info "Note: Let's Encrypt certificate was not removed"
    else
        echo_info "Removal cancelled"
    fi
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo_info "Organizr Setup"

    _install_organizr

    local state
    state=$(_get_install_state)

    if [ "$state" != "subdomain" ]; then
        if ask "Convert Organizr to subdomain mode?" N; then
            _prompt_domain
            _prompt_le_mode
            _install
        fi
    else
        echo_info "Subdomain already configured"
        if ask "Reconfigure SSO protected apps?" N; then
            _configure
        fi
    fi

    echo_success "Organizr setup complete"
}

# ==============================================================================
# Main
# ==============================================================================

_preflight "${1:-}"

case "${1:-}" in
    "--subdomain")
        case "${2:-}" in
            "--revert") _revert ;;
            "") _install ;;
            *)
                echo "Usage: $0 --subdomain [--revert]"
                exit 1
                ;;
        esac
        ;;
    "--configure")
        _configure
        ;;
    "--migrate")
        echo_info "Checking for misconfigured auth placement..."
        _migrate_all_apps
        ;;
    "--register-panel")
        if [ ! -f /install/.organizr.lock ]; then
            echo_error "Organizr is not installed"
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
        echo_success "Panel registration updated for Organizr"
        ;;
    "--remove")
        _remove
        ;;
    "")
        _interactive
        ;;
    *)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "  (no args)             Interactive setup"
        echo "  --subdomain           Convert to subdomain mode"
        echo "  --subdomain --revert  Revert to subfolder mode"
        echo "  --configure           Modify which apps are protected"
        echo "  --migrate             Fix auth_request placement in redirect blocks"
        echo "  --register-panel      Re-register with panel (restore urloverride)"
        echo "  --remove              Completely remove Organizr"
        exit 1
        ;;
esac
