#!/bin/bash
set -euo pipefail
# seerr - Extended Seerr installer with subdomain support
# STiXzoOR 2025
# Usage: bash seerr.sh [--subdomain [--revert]|--remove [--force]|--register-panel]

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

app_name="seerr"
app_lockname="${app_name//-/}"
fnm_install_url="https://fnm.vercel.app/install"
app_reqs=("curl" "jq" "wget")
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/overseerr.png"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Helper Functions
# ==============================================================================

_get_owner() {
    if ! SEERR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
        SEERR_OWNER="$(_get_master_username)"
    fi
    echo "$SEERR_OWNER"
}

_get_organizr_domain() {
    if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
        grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
    fi
}

# ==============================================================================
# Domain/LE Helper Functions
# ==============================================================================

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "${app_name}/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${SEERR_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${SEERR_DOMAIN:-}" ]; then
        echo_info "Using domain from SEERR_DOMAIN: $SEERR_DOMAIN"
        app_domain="$SEERR_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Seerr" "[$existing_domain]"
    else
        echo_query "Enter domain for Seerr" "(e.g., seerr.example.com)"
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
    export SEERR_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${SEERR_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from SEERR_LE_INTERACTIVE: $SEERR_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export SEERR_LE_INTERACTIVE="yes"
    else
        export SEERR_LE_INTERACTIVE="no"
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
    local le_hostname="${SEERR_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${SEERR_LE_INTERACTIVE:-no}"

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
# Base App Installation
# ==============================================================================

_install_app() {
    local user
    user=$(_get_owner)
    local app_group="$user"
    local swiz_configdir="/home/$user/.config"
    local app_configdir="$swiz_configdir/${app_name^}"
    local app_dir="/opt/$app_name"
    local app_port

    if [ -f "/install/.${app_lockname}.lock" ]; then
        echo_info "${app_name^} already installed"
        return
    fi

    _cleanup_needed=true
    echo_info "Installing ${app_name^}..."

    # Get a port for the app
    app_port=$(port 10000 12000)

    # Save owner
    swizdb set "$app_name/owner" "$user"
    swizdb set "$app_name/port" "$app_port"

    # Config + logs under user's ~/.config/Seerr
    if [ ! -d "$swiz_configdir" ]; then
        mkdir -p "$swiz_configdir"
    fi
    chown "$user":"$user" "$swiz_configdir"

    if [ ! -d "$app_configdir" ]; then
        mkdir -p "$app_configdir"
    fi
    if [ ! -d "$app_configdir/logs" ]; then
        mkdir -p "$app_configdir/logs"
    fi
    chown -R "$user":"$user" "$app_configdir"

    # OS-level deps
    apt_install "${app_reqs[@]}"

    # Install fnm, Node LTS and pnpm for app user
    echo_progress_start "Installing fnm, Node LTS and pnpm for $user"

    if ! su - "$user" -c 'command -v fnm >/dev/null 2>&1'; then
        su - "$user" -c "curl -fsSL \"$fnm_install_url\" | bash" >>"$log" 2>&1 || {
            echo_error "Failed to install fnm"
            exit 1
        }
    fi

    # Source fnm environment and install Node LTS + pnpm
    local fnm_env='export FNM_PATH="$HOME/.local/share/fnm"; export PATH="$FNM_PATH:$PATH"; eval "$(fnm env)"'
    su - "$user" -c "$fnm_env; fnm install lts-latest && fnm use lts-latest && fnm default lts-latest && npm install -g pnpm@10" >>"$log" 2>&1 || {
        echo_error "Failed to install Node LTS and pnpm via fnm"
        exit 1
    }

    # Resolve absolute Node path and bake into systemd
    local node_path
    node_path="$(su - "$user" -c "$fnm_env; which node" 2>>"$log")"
    if [ -z "$node_path" ]; then
        echo_error "Could not resolve Node path"
        exit 1
    fi
    echo_info "Using Node binary at: $node_path"

    echo_progress_done "fnm, Node LTS and pnpm installed"

    echo_progress_start "Cloning Seerr source code"

    git clone --depth 1 https://github.com/seerr-team/seerr.git "$app_dir" >>"$log" 2>&1 || {
        echo_error "Failed to clone Seerr repository"
        exit 1
    }
    chown -R "$user":"$user" "$app_dir"
    echo_progress_done "Seerr source code cloned to $app_dir"

    echo_progress_start "Configuring and building Seerr"

    # Bypass Node engine strictness if present
    if [ -f "$app_dir/.npmrc" ]; then
        sed -i 's|engine-strict=true|engine-strict=false|g' "$app_dir/.npmrc" || true
    fi

    # Optional CPU limit tweak in next.config.js
    if [ -f "$app_dir/next.config.js" ]; then
        sed -i "s|256000,|256000,\n    cpus: 6,|g" "$app_dir/next.config.js" || true
    fi

    # Install deps + build using pnpm as the app user
    su - "$user" -c "$fnm_env; cd '$app_dir' && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile" >>"$log" 2>&1 || {
        echo_error "Failed to install Seerr dependencies"
        exit 1
    }

    # Build for root path (subdomain), Seerr base URL = "/"
    su - "$user" -c "$fnm_env; cd '$app_dir' && seerr_BASEURL='/' pnpm build" >>"$log" 2>&1 || {
        echo_error "Failed to build Seerr"
        exit 1
    }

    echo_progress_done "Seerr built successfully"

    # Write env file
    cat >"$app_configdir/env.conf" <<EOF
# Seerr environment
PORT=$app_port
seerr_BASEURL="/"
EOF

    chown -R "$user":"$user" "$app_configdir"

    # Install systemd service
    echo_progress_start "Installing Systemd service"

    cat >"/etc/systemd/system/${app_name}.service" <<EOF
[Unit]
Description=${app_name^} Service
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
User=${user}
Group=${app_group}
UMask=002
EnvironmentFile=$app_configdir/env.conf
Environment=NODE_ENV=production
Environment=CONFIG_DIRECTORY=$app_configdir
WorkingDirectory=$app_dir
ExecStart=$node_path dist/index.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
SyslogIdentifier=$app_name

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectClock=true
ProtectControlGroups=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
RemoveIPC=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native
SystemCallErrorNumber=EPERM
SystemCallFilter=@system-service
SystemCallFilter=~@privileged

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="${app_name}.service"
    systemctl -q daemon-reload
    systemctl enable --now -q "${app_name}.service"
    sleep 1
    echo_progress_done "${app_name^} service installed and enabled"
    echo_info "${app_name^} is running on http://127.0.0.1:$app_port/"

    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
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
    local app_port
    local organizr_domain

    app_port=$(swizdb get "$app_name/port" 2>/dev/null) || app_port=10000
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
        include snippets/proxy.conf;
        proxy_pass http://127.0.0.1:${app_port};
    }
}
VHOST

    _nginx_config_written="$subdomain_vhost"
    [ -L "$subdomain_enabled" ] || ln -s "$subdomain_vhost" "$subdomain_enabled"
    _nginx_symlink_created="$subdomain_enabled"

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

    # Seerr is NOT a built-in Swizzin app, so create standalone class (no inheritance)
    cat >>"$profiles_py" <<PYTHON

class ${app_name}_meta:
    name = "${app_name}"
    pretty_name = "Seerr"
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
# Subdomain Install/Revert
# ==============================================================================

_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${SEERR_LE_HOSTNAME:-$domain}"
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
        "installed")
            _request_certificate "$domain"
            _create_subdomain_vhost "$domain" "$le_hostname"
            _add_panel_meta "$domain"
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
    echo_info "Reverting ${app_name^} to direct port access..."

    [ -L "$subdomain_enabled" ] && rm -f "$subdomain_enabled"
    [ -f "$subdomain_vhost" ] && rm -f "$subdomain_vhost"

    _remove_panel_meta

    _reload_nginx
    local app_port
    app_port=$(swizdb get "$app_name/port" 2>/dev/null) || app_port=10000
    echo_success "${app_name^} reverted to direct access"
    echo_info "Access at: http://your-server:${app_port}/"
}

# ==============================================================================
# Complete Removal
# ==============================================================================

_remove() {
    local force="${1:-}"
    if [ "$force" != "--force" ] && [ ! -f "/install/.${app_lockname}.lock" ]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    local user
    user=$(_get_owner)
    local app_configdir="/home/$user/.config/${app_name^}"
    local app_dir="/opt/$app_name"

    # Ask about purging configuration
    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and disable service
    echo_progress_start "Stopping and disabling ${app_name^} service"
    systemctl stop "${app_name}.service" 2>/dev/null || true
    systemctl disable "${app_name}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_name}.service"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove application directory
    echo_progress_start "Removing ${app_name^} application"
    rm -rf "$app_dir"
    echo_progress_done "Application removed"

    # Remove nginx vhost
    if [ -f "$subdomain_vhost" ] || [ -L "$subdomain_enabled" ]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove from panel
    _remove_panel_meta

    # Remove backup dir
    rm -rf "$backup_dir"

    # Remove config directory if purging
    if [ "$purgeconfig" = "true" ]; then
        echo_progress_start "Purging configuration files"
        rm -rf "$app_configdir"
        echo_progress_done "Configuration purged"
        swizdb clear "$app_name/owner" 2>/dev/null || true
        swizdb clear "$app_name/port" 2>/dev/null || true
        swizdb clear "$app_name/domain" 2>/dev/null || true
    else
        echo_info "Configuration files kept at: $app_configdir"
    fi

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

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
        if ask "Configure Seerr with a subdomain?" N; then
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
    echo "  --subdomain --revert  Revert to direct port access"
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
