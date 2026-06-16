#!/bin/bash
set -euo pipefail
# netdata installer
# STiXzoOR 2026
# Usage: bash netdata.sh [--update [--verbose]|--remove [--force]|--register-panel]
#
# Installs Netdata via upstream kickstart (--stable-channel, non-interactive,
# telemetry disabled). Netdata supplies its own systemd service, updater, and
# uninstaller; this wrapper only:
#   - runs the kickstart
#   - rebinds the web UI to 127.0.0.1 (nginx fronts it)
#   - generates an htpasswd-protected nginx apps conf for the swizzin panel
#   - registers the app with the panel + lock file
#   - delegates updates to netdata-updater.sh
#   - delegates removal to netdata-uninstaller.sh
#
# NETDATA_CLAIM_TOKEN + NETDATA_CLAIM_ROOMS env vars, if set, are forwarded
# to kickstart so the node claims to Netdata Cloud on first install.

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

export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
        _reload_nginx 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Verbose
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
app_name="netdata"
app_pretty="Netdata"
app_lockname="${app_name//-/}"
app_baseurl="${app_name}"
app_port=19999  # Netdata's fixed default
app_servicefile="netdata.service"
app_reqs=("curl" "ca-certificates")
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/netdata.png"

# Netdata paths (fixed by upstream)
netdata_config="/etc/netdata/netdata.conf"
netdata_updater="/usr/libexec/netdata/netdata-updater.sh"
netdata_uninstaller="/usr/libexec/netdata/netdata-uninstaller.sh"

# Owner (drives htpasswd lookup — htpasswd.${user} is the swizzin convention)
if ! NETDATA_OWNER="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    NETDATA_OWNER="$(_get_master_username)"
fi
user="$NETDATA_OWNER"

# ==============================================================================
# Kickstart-based install
# ==============================================================================
_install_netdata() {
    apt_install "${app_reqs[@]}"

    echo_progress_start "Running Netdata kickstart installer"

    local _tmp_kickstart
    _tmp_kickstart=$(mktemp "/tmp/netdata-kickstart-XXXXXX.sh")

    if ! curl -fsSL "https://get.netdata.cloud/kickstart.sh" -o "$_tmp_kickstart" >>"$log" 2>&1; then
        echo_error "Failed to download Netdata kickstart.sh"
        rm -f "$_tmp_kickstart"
        exit 1
    fi

    local kickstart_args=(
        --stable-channel
        --disable-telemetry
        --dont-wait
        --non-interactive
        --no-updates
    )

    # Forward Netdata Cloud claim credentials if provided via environment.
    if [[ -n "${NETDATA_CLAIM_TOKEN:-}" ]]; then
        kickstart_args+=(--claim-token "$NETDATA_CLAIM_TOKEN")
        if [[ -n "${NETDATA_CLAIM_ROOMS:-}" ]]; then
            kickstart_args+=(--claim-rooms "$NETDATA_CLAIM_ROOMS")
        fi
        if [[ -n "${NETDATA_CLAIM_URL:-}" ]]; then
            kickstart_args+=(--claim-url "$NETDATA_CLAIM_URL")
        fi
    fi

    if ! bash "$_tmp_kickstart" "${kickstart_args[@]}" >>"$log" 2>&1; then
        echo_error "Netdata kickstart failed (see $log)"
        rm -f "$_tmp_kickstart"
        exit 1
    fi
    rm -f "$_tmp_kickstart"
    echo_progress_done "Netdata installed"

    # Re-enable automatic updates managed by netdata-updater.sh crontab.
    # Kickstart was run with --no-updates so swizzin's --update flag stays
    # in control; flip this if the user wants netdata self-updating.
}

# ==============================================================================
# Bind to localhost only
# ==============================================================================
_configure_netdata() {
    echo_progress_start "Configuring Netdata to bind to 127.0.0.1"

    if [[ ! -f "$netdata_config" ]]; then
        # Fresh install with no config yet — generate one Netdata will recognise.
        cat >"$netdata_config" <<EOF
# Managed by swizzin-scripts/netdata.sh
[global]
    hostname = $(hostname -s)

[web]
    bind to = 127.0.0.1
    allow connections from = localhost 127.0.0.1
    allow dashboard from = localhost 127.0.0.1
EOF
    else
        # Preserve user customisations, only update the [web] bind line.
        if grep -q "^\s*bind to" "$netdata_config"; then
            sed -i 's|^\([[:space:]]*bind to[[:space:]]*=\).*|\1 127.0.0.1|' "$netdata_config"
        else
            # Append [web] section if missing.
            if ! grep -q "^\s*\[web\]" "$netdata_config"; then
                printf '\n[web]\n    bind to = 127.0.0.1\n' >> "$netdata_config"
            else
                sed -i '/^\s*\[web\]/a\    bind to = 127.0.0.1' "$netdata_config"
            fi
        fi
    fi

    chown netdata:netdata "$netdata_config" 2>/dev/null || true
    echo_progress_done "Netdata bound to 127.0.0.1:${app_port}"
}

# ==============================================================================
# Update (delegated to netdata-updater.sh)
# ==============================================================================
_update_netdata() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    if [[ ! -x "$netdata_updater" ]]; then
        echo_error "Netdata updater not found at $netdata_updater"
        echo_info "Falling back to re-running kickstart"
        _install_netdata
        _configure_netdata
        systemctl restart "$app_servicefile"
        echo_success "${app_pretty} reinstalled from kickstart"
        exit 0
    fi

    echo_info "Updating ${app_pretty} via netdata-updater.sh..."
    echo_progress_start "Running Netdata updater"

    if ! "$netdata_updater" --non-interactive >>"$log" 2>&1; then
        echo_error "netdata-updater.sh failed (see $log)"
        exit 1
    fi
    echo_progress_done "Netdata updated"

    # Re-apply bind config in case the update replaced it.
    _configure_netdata
    systemctl restart "$app_servicefile"

    echo_success "${app_pretty} updated"
    exit 0
}

# ==============================================================================
# Removal (delegated to netdata-uninstaller.sh)
# ==============================================================================
_remove_netdata() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig="false"
    if ask "Would you like to purge the Netdata configuration and data?" N; then
        purgeconfig="true"
    fi

    # Stop service (best-effort; uninstaller handles this too)
    systemctl stop "$app_servicefile" 2>/dev/null || true

    # Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/${app_name}.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Run upstream uninstaller (handles binaries, systemd, native package)
    if [[ -x "$netdata_uninstaller" ]]; then
        echo_progress_start "Running netdata-uninstaller"
        local uninstaller_args=(--yes)
        if [[ "$purgeconfig" == "true" ]]; then
            uninstaller_args+=(--force)
        fi
        "$netdata_uninstaller" "${uninstaller_args[@]}" >>"$log" 2>&1 || {
            echo_info "netdata-uninstaller returned non-zero; continuing"
        }
        echo_progress_done "Netdata uninstalled"
    else
        echo_info "netdata-uninstaller.sh not found — package may already be removed"
    fi

    if [[ "$purgeconfig" == "true" ]]; then
        rm -rf /etc/netdata /var/lib/netdata /var/cache/netdata /var/log/netdata
        swizdb clear "${app_name}/owner" 2>/dev/null || true
    fi

    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_netdata() {
    if [[ ! -f /install/.nginx.lock ]]; then
        echo_info "${app_pretty} is listening on 127.0.0.1:${app_port} (no nginx lock, skipping reverse proxy)"
        return
    fi

    echo_progress_start "Configuring nginx"

    local _nginx_conf="/etc/nginx/apps/${app_name}.conf"
    _nginx_config_written="$_nginx_conf"
    _cleanup_needed=true

    # Subfolder route under the panel domain — e.g. https://panel.example.com/netdata/
    # Netdata exposes its dashboard at the root, so we strip the /netdata/ prefix
    # when proxying upstream. WebSocket upgrade required for the live dashboard.
    cat >"$_nginx_conf" <<NGX
location = /${app_baseurl} {
    return 301 /${app_baseurl}/;
}

location /${app_baseurl}/ {
    proxy_pass http://127.0.0.1:${app_port}/;
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;

    proxy_redirect off;
    proxy_buffering off;

    # Dashboard live charts — keep connection open for SSE/WebSocket.
    proxy_read_timeout 3600;

    # Netdata response compression can conflict with nginx gzip; rely on
    # netdata's own compression (enabled by default on [web]).
    gzip off;

    auth_basic "Netdata";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
}
NGX

    _reload_nginx
    echo_progress_done "Nginx configured (reverse proxy at /${app_baseurl}/ with htpasswd.${user})"
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

# Handle --remove
if [[ "${1:-}" == "--remove" ]]; then
    _remove_netdata "${2:-}"
fi

# Handle --update
if [[ "${1:-}" == "--update" ]]; then
    _update_netdata
fi

# Handle --register-panel
if [[ "${1:-}" == "--register-panel" ]]; then
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "$app_pretty" \
            "/${app_baseurl}" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_pretty}"
    else
        echo_error "Panel helper not available"
        exit 1
    fi
    exit 0
fi

# Already installed?
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_error "${app_pretty} is already installed"
    exit 1
fi

_cleanup_needed=true

echo_info "Setting ${app_pretty} owner = ${user}"
swizdb set "${app_name}/owner" "$user"

_install_netdata
_configure_netdata

echo_progress_start "Restarting Netdata"
systemctl daemon-reload
systemctl enable "$app_servicefile" >>"$log" 2>&1
systemctl restart "$app_servicefile"
sleep 2
if ! systemctl is-active --quiet "$app_servicefile"; then
    echo_error "Netdata service failed to start (see: journalctl -u $app_servicefile)"
    exit 1
fi
echo_progress_done "Netdata running on 127.0.0.1:${app_port}"

_nginx_netdata

# Register with panel
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "$app_pretty" \
        "/${app_baseurl}" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

_lock_file_created="/install/.${app_lockname}.lock"
touch "$_lock_file_created"
_cleanup_needed=false

echo_success "${app_pretty} installed"
if [[ -f /install/.nginx.lock ]]; then
    echo_info "Access at: https://<panel-domain>/${app_baseurl}/ (login: ${user} / htpasswd)"
else
    echo_info "Access at: http://<server-ip>:${app_port}/ (no nginx detected; netdata is bound to 127.0.0.1 — SSH tunnel required)"
fi
