#!/bin/bash
set -euo pipefail
# adguardhome installer
# STiXzoOR 2026
# Usage: bash adguardhome.sh [--update [--verbose]|--remove [--force]|--register-panel]
#
# Installs AdGuard Home as a DNS+filtering resolver bound to 127.0.0.1:
#   - DNS server on 127.0.0.1:5353 (non-privileged, no systemd-resolved conflict)
#   - Admin web UI on 127.0.0.1:<allocated-port>, fronted by nginx + htpasswd
#   - Runs as dedicated `adguardhome` system user
#
# Does NOT modify /etc/systemd/resolved.conf or /etc/resolv.conf — system DNS
# is untouched. To forward systemd-resolved through AdGuard Home, after install:
#   echo -e '[Resolve]\nDNS=127.0.0.1:5353\nDNSStubListener=yes' \
#     > /etc/systemd/resolved.conf.d/00-adguardhome.conf
#   systemctl restart systemd-resolved
# (Reverse by deleting the drop-in and restarting systemd-resolved.)
#
# Admin credentials (username = swizzin master user, randomly-generated
# password) are printed once at the end of install and stored in swizdb under
# adguardhome/admin_password for later retrieval.

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
_systemd_unit_written=""
_lock_file_created=""
_install_dir_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
            systemctl daemon-reload
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
        [[ -n "$_install_dir_created" && -d "$_install_dir_created" ]] && rm -rf "$_install_dir_created"
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
app_name="adguardhome"
app_pretty="AdGuardHome"
app_lockname="${app_name//-/}"
app_baseurl="${app_name}"
app_dir="/opt/AdGuardHome"
app_binary="${app_dir}/AdGuardHome"
app_config="${app_dir}/AdGuardHome.yaml"
app_dns_port=5353
app_servicefile="${app_name}.service"
app_sysuser="adguardhome"
app_reqs=("curl" "apache2-utils" "yq")
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/adguard-home.png"

# Admin web port (prefer existing from config if present, else allocate fresh)
app_port=""
if [[ -f "$app_config" ]]; then
    app_port=$(grep -oE '^\s*address:\s*127\.0\.0\.1:[0-9]+' "$app_config" 2>/dev/null \
        | grep -oE '[0-9]+$' | head -1 || true)
fi
app_port="${app_port:-$(port 10000 12000)}"

# Owner (used to pick the htpasswd file that fronts the web UI)
if ! ADGUARDHOME_OWNER="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    ADGUARDHOME_OWNER="$(_get_master_username)"
fi
user="$ADGUARDHOME_OWNER"

# ==============================================================================
# Helpers
# ==============================================================================

# Pick the GitHub release asset for the host architecture.
_adguardhome_asset_filter() {
    case "$(_os_arch)" in
        "amd64") echo "linux_amd64.tar.gz" ;;
        "arm64") echo "linux_arm64.tar.gz" ;;
        "armhf") echo "linux_armv6.tar.gz" ;;
        *)
            echo_error "Architecture not supported by AdGuard Home"
            exit 1
            ;;
    esac
}

# Return the newest release tarball URL (GitHub "latest" release).
_adguardhome_latest_url() {
    local asset
    asset=$(_adguardhome_asset_filter)
    curl -fsSL "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" \
        | grep "browser_download_url" \
        | grep "${asset}" \
        | cut -d\" -f4 \
        | head -1
}

# Ensure the dedicated adguardhome system user exists.
_ensure_sysuser() {
    if ! id -u "$app_sysuser" >/dev/null 2>&1; then
        _verbose "Creating system user ${app_sysuser}"
        useradd --system --no-create-home --shell /usr/sbin/nologin "$app_sysuser"
    fi
}

# Generate a random 24-character password and its bcrypt hash.
# Returns two lines: plaintext on stdout line 1, hash on stdout line 2.
_generate_admin_credentials() {
    local plaintext hash
    plaintext=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
    # htpasswd -B = bcrypt; -n = print, don't write file; -b = inline password
    hash=$(htpasswd -nbB "$user" "$plaintext" 2>/dev/null | cut -d: -f2)
    printf '%s\n%s\n' "$plaintext" "$hash"
}

# ==============================================================================
# Install
# ==============================================================================
_install_adguardhome() {
    apt_install "${app_reqs[@]}"
    _ensure_sysuser

    echo_progress_start "Downloading AdGuard Home release"
    local _tmp_download
    _tmp_download=$(mktemp "/tmp/${app_name}-XXXXXX.tar.gz")

    local url
    url=$(_adguardhome_latest_url)
    if [[ -z "$url" ]]; then
        echo_error "Could not locate a release tarball for this architecture"
        rm -f "$_tmp_download"
        exit 1
    fi
    _verbose "Tarball URL: $url"

    if ! curl -fsSL "$url" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        rm -f "$_tmp_download"
        exit 1
    fi
    echo_progress_done "Download complete"

    echo_progress_start "Extracting archive"
    # The tarball contains a top-level AdGuardHome/ directory with the binary.
    local existed_before="false"
    [[ -d "$app_dir" ]] && existed_before="true"
    tar -xf "$_tmp_download" -C /opt/ >>"$log" 2>&1 || {
        echo_error "Failed to extract archive"
        rm -f "$_tmp_download"
        exit 1
    }
    rm -f "$_tmp_download"
    [[ "$existed_before" == "false" ]] && _install_dir_created="$app_dir"
    chmod +x "$app_binary"
    echo_progress_done "Binary extracted to ${app_dir}"

    # Pre-seed the minimum config so the first run binds to our allocated
    # port. Skip if the user already has a config (preserves customizations).
    if [[ ! -f "$app_config" ]]; then
        local plaintext hash creds
        creds=$(_generate_admin_credentials)
        plaintext=$(echo "$creds" | sed -n '1p')
        hash=$(echo "$creds" | sed -n '2p')

        echo_progress_start "Writing initial config"
        cat >"$app_config" <<YAML
# Managed by swizzin-scripts/adguardhome.sh
# Further tuning happens in the web UI; this file is authoritative on restart.
http:
  address: 127.0.0.1:${app_port}
  session_ttl: 720h
users:
  - name: ${user}
    password: '${hash}'
language: en
theme: auto
dns:
  bind_hosts:
    - 127.0.0.1
  port: ${app_dns_port}
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.quad9.net/dns-query
    - tls://1.1.1.1
    - tls://9.9.9.9
  bootstrap_dns:
    - 1.1.1.1
    - 9.9.9.9
    - 8.8.8.8
  cache_size: 67108864
  cache_ttl_min: 60
  cache_ttl_max: 86400
  ratelimit: 0
  enable_dnssec: true
  aaaa_disabled: false
  anonymize_client_ip: false
  edns_client_subnet:
    enabled: false
  upstream_mode: load_balance
  use_private_ptr_resolvers: true
  enable_ech: true
tls:
  enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: false
    dhcp: false
    hosts: true
log:
  enabled: true
  file: ""
  compress: false
  local_time: false
  max_backups: 0
  max_size: 100
  max_age: 3
schema_version: 29
YAML
        chmod 600 "$app_config"

        # Store admin plaintext in swizdb for later retrieval. swizdb
        # already lives in /etc/swizzin (root-only).
        swizdb set "${app_name}/admin_password" "$plaintext"
        swizdb set "${app_name}/admin_user" "$user"

        echo_progress_done "Config written with bcrypt-hashed admin password"

        # Stash the plaintext for the install summary at the end.
        _ADGUARDHOME_INITIAL_PASSWORD="$plaintext"
    else
        echo_info "Existing config found at ${app_config}, preserving it"
        _ADGUARDHOME_INITIAL_PASSWORD=""
    fi

    chown -R "${app_sysuser}:${app_sysuser}" "$app_dir"
}

# ==============================================================================
# Systemd
# ==============================================================================
_systemd_adguardhome() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=AdGuard Home: Network-wide ad blocking DNS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${app_sysuser}
Group=${app_sysuser}
WorkingDirectory=${app_dir}
ExecStart=${app_binary} --no-check-update -w ${app_dir} -c ${app_config}
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${app_dir}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="$app_servicefile"
    systemctl daemon-reload
    systemctl enable "$app_servicefile" >>"$log" 2>&1
    systemctl start "$app_servicefile"
    sleep 2

    if ! systemctl is-active --quiet "$app_servicefile"; then
        echo_error "AdGuard Home service failed to start (see: journalctl -u $app_servicefile)"
        exit 1
    fi
    echo_progress_done "Service running on 127.0.0.1:${app_port} (web) + 127.0.0.1:${app_dns_port} (dns)"
}

# ==============================================================================
# Nginx
# ==============================================================================
_nginx_adguardhome() {
    if [[ ! -f /install/.nginx.lock ]]; then
        echo_info "${app_pretty} web UI is on 127.0.0.1:${app_port} (no nginx lock, skipping reverse proxy)"
        return
    fi

    echo_progress_start "Configuring nginx"
    local _nginx_conf="/etc/nginx/apps/${app_name}.conf"
    _nginx_config_written="$_nginx_conf"

    # AdGuard Home has no upstream base_url option, so its redirects and some
    # absolute-path references need to be rewritten on the way back:
    #   - 302 Location: /login.html      -> /${app_baseurl}/login.html
    #   - bodies mentioning /control/    -> /${app_baseurl}/control/
    # Accept-Encoding is blanked so upstream never gzips and sub_filter works.
    # /${app_baseurl}/control/ has its own block without auth_basic so the
    # SPA's JSON fetches use AdGuard's session cookie, not the outer auth.
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
    proxy_set_header Accept-Encoding "";

    proxy_buffering off;

    # Rewrite Location: /login.html -> /${app_baseurl}/login.html
    proxy_redirect ~^/(.*)\$ /${app_baseurl}/\$1;

    # Rewrite absolute-path URLs that the upstream HTML/JS/CSS might emit.
    # (text/html is in the default sub_filter_types; listing it explicitly
    # would emit a "duplicate MIME type" warning.)
    sub_filter_once off;
    sub_filter_types text/css text/javascript application/javascript application/json;
    sub_filter 'href="/' 'href="/${app_baseurl}/';
    sub_filter "href='/" "href='/${app_baseurl}/";
    sub_filter 'src="/' 'src="/${app_baseurl}/';
    sub_filter "src='/" "src='/${app_baseurl}/";
    sub_filter 'action="/' 'action="/${app_baseurl}/';
    sub_filter '"/control/' '"/${app_baseurl}/control/';
    sub_filter "'/control/" "'/${app_baseurl}/control/";
    sub_filter '"/login.html' '"/${app_baseurl}/login.html';
    sub_filter '"/install.html' '"/${app_baseurl}/install.html';
    sub_filter '"/assets/' '"/${app_baseurl}/assets/';
    sub_filter '"/favicon' '"/${app_baseurl}/favicon';

    auth_basic "AdGuard Home";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
}

# AdGuard's REST API — bypass the outer htpasswd so the SPA's cookie-auth'd
# JSON calls can reach it without double-prompting.
location /${app_baseurl}/control/ {
    proxy_pass http://127.0.0.1:${app_port}/control/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_buffering off;
}
NGX

    _reload_nginx
    echo_progress_done "Nginx configured (reverse proxy at /${app_baseurl}/ with htpasswd.${user})"
}

# ==============================================================================
# Update
# ==============================================================================
_update_adguardhome() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    # Back up the current binary for rollback.
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"
    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    if [[ -f "$app_binary" ]]; then
        cp "$app_binary" "${backup_dir}/AdGuardHome"
        _verbose "Backup saved to ${backup_dir}"
    fi

    systemctl stop "$app_servicefile" 2>/dev/null || true

    echo_progress_start "Downloading latest release"
    local _tmp_download url
    _tmp_download=$(mktemp "/tmp/${app_name}-XXXXXX.tar.gz")
    url=$(_adguardhome_latest_url)
    if [[ -z "$url" ]]; then
        echo_error "Could not locate a release tarball"
        systemctl start "$app_servicefile" 2>/dev/null || true
        rm -f "$_tmp_download"
        exit 1
    fi

    if ! curl -fsSL "$url" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed, rolling back"
        [[ -f "${backup_dir}/AdGuardHome" ]] && cp "${backup_dir}/AdGuardHome" "$app_binary"
        systemctl start "$app_servicefile" 2>/dev/null || true
        rm -f "$_tmp_download"
        exit 1
    fi
    echo_progress_done "Downloaded"

    echo_progress_start "Installing new binary"
    # Extract only the binary, leave config/data in place.
    local _tmp_extract
    _tmp_extract=$(mktemp -d "/tmp/${app_name}-extract-XXXXXX")
    tar -xf "$_tmp_download" -C "$_tmp_extract" --strip-components=1 AdGuardHome/AdGuardHome >>"$log" 2>&1 || {
        echo_error "Failed to extract binary"
        [[ -f "${backup_dir}/AdGuardHome" ]] && cp "${backup_dir}/AdGuardHome" "$app_binary"
        systemctl start "$app_servicefile" 2>/dev/null || true
        rm -rf "$_tmp_extract" "$_tmp_download"
        exit 1
    }
    mv "${_tmp_extract}/AdGuardHome" "$app_binary"
    chmod +x "$app_binary"
    chown "${app_sysuser}:${app_sysuser}" "$app_binary"
    rm -rf "$_tmp_extract" "$_tmp_download"
    echo_progress_done "Binary replaced"

    systemctl start "$app_servicefile"
    sleep 2
    if ! systemctl is-active --quiet "$app_servicefile"; then
        echo_error "Service failed to start after update, rolling back"
        [[ -f "${backup_dir}/AdGuardHome" ]] && cp "${backup_dir}/AdGuardHome" "$app_binary"
        chmod +x "$app_binary"
        chown "${app_sysuser}:${app_sysuser}" "$app_binary"
        systemctl start "$app_servicefile"
        exit 1
    fi

    rm -rf "$backup_dir"
    echo_success "${app_pretty} updated"
    exit 0
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_adguardhome() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig="false"
    if ask "Would you like to purge ${app_dir} (config + filter cache)?" N; then
        purgeconfig="true"
    fi

    # Warn if systemd-resolved integration was set up (we don't own that file,
    # but call out the footgun before the DNS disappears).
    if [[ -f /etc/systemd/resolved.conf.d/00-adguardhome.conf ]]; then
        echo_info "Detected /etc/systemd/resolved.conf.d/00-adguardhome.conf —"
        echo_info "remove it manually to stop systemd-resolved forwarding through AdGuard Home"
    fi

    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload

    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/${app_name}.conf"
        systemctl reload nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        panel_unregister_app "$app_name" 2>/dev/null || true
    fi

    if [[ "$purgeconfig" == "true" ]]; then
        rm -rf "$app_dir"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/admin_password" 2>/dev/null || true
        swizdb clear "${app_name}/admin_user" 2>/dev/null || true
        if id -u "$app_sysuser" >/dev/null 2>&1; then
            userdel "$app_sysuser" 2>/dev/null || true
        fi
    else
        echo_info "Config kept at ${app_dir}"
    fi

    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Main
# ==============================================================================

for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

if [[ "${1:-}" == "--remove" ]]; then
    _remove_adguardhome "${2:-}"
fi

if [[ "${1:-}" == "--update" ]]; then
    _update_adguardhome
fi

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

if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_error "${app_pretty} is already installed"
    exit 1
fi

_cleanup_needed=true

echo_info "Setting ${app_pretty} owner = ${user}"
swizdb set "${app_name}/owner" "$user"

_install_adguardhome
_systemd_adguardhome
_nginx_adguardhome

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
if [[ -n "${_ADGUARDHOME_INITIAL_PASSWORD:-}" ]]; then
    echo_info "=============================================================="
    echo_info "INITIAL ADMIN CREDENTIALS (shown once, also in swizdb):"
    echo_info "  Username: ${user}"
    echo_info "  Password: ${_ADGUARDHOME_INITIAL_PASSWORD}"
    echo_info "=============================================================="
    echo_info "Retrieve later: swizdb get ${app_name}/admin_password"
fi
if [[ -f /install/.nginx.lock ]]; then
    echo_info "Web UI: https://<panel-domain>/${app_baseurl}/ (htpasswd.${user} + admin creds above)"
else
    echo_info "Web UI: http://<server-ip>:${app_port}/ (bound to 127.0.0.1 — SSH tunnel required)"
fi
echo_info "DNS server: 127.0.0.1:${app_dns_port}"
echo_info ""
echo_info "To route systemd-resolved through AdGuard Home:"
echo_info "  mkdir -p /etc/systemd/resolved.conf.d/"
echo_info "  cat > /etc/systemd/resolved.conf.d/00-adguardhome.conf <<'EOF'"
echo_info "  [Resolve]"
echo_info "  DNS=127.0.0.1:${app_dns_port}"
echo_info "  FallbackDNS=1.1.1.1 9.9.9.9"
echo_info "  DNSStubListener=yes"
echo_info "  EOF"
echo_info "  systemctl restart systemd-resolved"
