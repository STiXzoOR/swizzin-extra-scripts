#!/bin/bash
set -euo pipefail
# notifiarr installer
# STiXzoOR 2025
# Usage: bash notifiarr.sh [--update [--full] [--verbose]|--remove [--force]] [--register-panel]

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
touch $log

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

app_name="notifiarr"

# Get owner from swizdb (needed for both install and remove)
if ! NOTIFIARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    NOTIFIARR_OWNER="$(_get_master_username)"
fi
user="$NOTIFIARR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl")
app_servicefile="$app_name.service"
app_dir="/usr/bin"
app_binary="$app_name"
app_lockname="${app_name//-/}"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/notifiarr.png"

if [ ! -d "$swiz_configdir" ]; then
    mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

_install_notifiarr() {
    if [ ! -d "$app_configdir" ]; then
        mkdir -p "$app_configdir"
    fi

    if [ ! -d "$app_configdir/logs" ]; then
        mkdir -p "$app_configdir/logs"
    fi

    chown -R "$user":"$user" "$app_configdir"

    apt_install "${app_reqs[@]}"

    echo_info "Checking for ${app_name} API Key"
    if ! grep -qE 'Environment=DN_API_KEY=[0-9a-fA-F-]{36}' "/etc/systemd/system/$app_servicefile" 2>/dev/null; then
        # Check for environment variable first
        if [ -n "${DN_API_KEY:-}" ]; then
            API_KEY="$DN_API_KEY"
            echo_info "Using API Key from DN_API_KEY environment variable"
        else
            echo_query "Paste your 'All' API Key from notifiarr.com profile page" ""
            read -r API_KEY </dev/tty

            if [ -z "$API_KEY" ]; then
                echo_error "API Key is required. Set DN_API_KEY or provide interactively. Cannot continue!"
                exit 1
            fi
        fi

        if ! echo "$API_KEY" | grep -q '^[0-9a-fA-F-]\{36\}$'; then
            echo_error "Invalid API Key format. Must be 36 characters (hexadecimal with dashes). Cannot continue!"
            exit 1
        fi
    fi

    echo_progress_start "Downloading release archive"

    local _tmp_download
    _tmp_download=$(mktemp /tmp/notifiarr-XXXXXX.gz)

    case "$(_os_arch)" in
        "amd64") arch='amd64' ;;
        "arm64") arch="arm64" ;;
        *)
            echo_error "Arch not supported"
            exit 1
            ;;
    esac

    latest=$(curl -sL https://api.github.com/repos/Notifiarr/notifiarr/releases/latest | grep "$arch" | grep browser_download_url | grep "linux.gz" | cut -d \" -f4) || {
        echo_error "Failed to query GitHub for latest version"
        exit 1
    }

    if ! curl "$latest" -L -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed, exiting"
        exit 1
    fi
    echo_progress_done "Archive downloaded"

    echo_progress_start "Extracting archive"
    if ! gunzip -c "$_tmp_download" >"$app_dir/$app_binary" 2>>"$log"; then
        echo_error "Failed to extract"
        exit 1
    fi
    rm -f "$_tmp_download"
    echo_progress_done "Archive extracted"

    chmod +x "$app_dir/$app_binary"

    echo_progress_start "Creating default config"
    cat >"$app_configdir/$app_name.conf" <<CFG
###############################################
# Notifiarr Client Example Configuration File #
# Created by Notifiarr v0.4.4   @ 232801T0734 #
###############################################

## This API key must be copied from your notifiarr.com account.
api_key = "${API_KEY}"

## Setting a UI password enables the human accessible web GUI. Must be at least 9 characters.
## The default username is admin; change it by setting ui_password to "username:password"
## Set to "webauth" to disable the login form and use only proxy authentication. See upstreams, below.
## Your auth proxy must pass the x-webauth-user header if you set this to "webauth".
## You may also set a custom auth header by setting to "webauth:<header>" e.g. "webauth:remote-user"
## Disable auth by setting this to "noauth". Not recommended. Requires "upstreams" being set.
ui_password = ""

## The ip:port to listen on for incoming HTTP requests. 0.0.0.0 means all/any IP and is recommended!
## You may use "127.0.0.1:5454" to listen only on localhost; good if using a local proxy.
## This is used to receive Plex webhooks and Media Request commands.
##
bind_addr = "127.0.0.1:${app_port}"

## This application can update itself on Windows systems.
## Set this to "daily" to check GitHub every day for updates.
## You may also set it to a Go duration like "12h" or "72h".
## THIS ONLY WORKS ON WINDOWS
auto_update = "off"

## Quiet makes the app not log anything to output.
## Recommend setting log files if you make the app quiet.
## This is always true on Windows and macOS app.
## Log files are automatically written on those platforms.
##
quiet = false

## Debug prints more data and json payloads. This increases application memory usage.
debug = false
max_body = 0 # maximum body size for debug logs. 0 = no limit.

## All API paths start with /api. This does not affect incoming /plex webhooks.
## Change it to /somethingelse/api by setting urlbase to "/somethingelse"
##
urlbase = "$app_baseurl"

## Allowed upstream networks. Networks here are allowed to send two special headers:
## (1) x-forwarded-for (2) x-webauth-user
## The first header sets the IPs in logs.
## The second header allows an auth proxy to set a logged-in username. Be careful.
##
## Set this to your reverse proxy server's IP or network. If you leave off the mask,
## then /32 or /128 is assumed depending on IP version. Empty by default. Example:
##
#upstreams = [ "127.0.0.1/32", "::1/128" ]

## If you provide a cert and key file (pem) paths, this app will listen with SSL/TLS.
## Uncomment both lines and add valid file paths. Make sure this app can read them.
##
#ssl_key_file  = '/path/to/cert.key'
#ssl_cert_file = '/path/to/cert.key'

## If you set these, logs will be written to these files.
## If blank on windows or macOS, log file paths are chosen for you.
#log_file = '~/.notifiarr/notifiarr.log'
#http_log = '~/.notifiarr/notifiarr.http.log'
##
## Set this to the number of megabytes to rotate files.
log_file_mb = 100
##
## How many files to keep? 0 = all.
log_files = 0
##
## Unix file mode for new log files. Umask also affects this.
## Missing, blank or 0 uses default of 0600. Permissive is 0644. Ignored by Windows.
file_mode = "0600"

## Web server and website timeout.
##
timeout = "1m"

## This application can integrate with apt on Debian-based OSes.
## Set apt to true to enable this integration. A true setting causes
## notifiarr to relay apt package install/update hooks to notifiarr.com.
##
apt = false

## Setting serial to true makes the app use fewer threads when polling apps.
## This spreads CPU usage out and uses a bit less memory.
serial = false

## Retries controls how many times to retry requests to notifiarr.com.
## Sometimes cloudflare returns a 521, and this mitigates those problems.
## Setting this to 0 will take the default of 4. Use 1 to disable retrying.
retries = 4

##################
# Starr Settings #
##################

## The API keys are specific to the app. Get it from Settings -> General.
## Configurations for unused apps are harmless. Set URL and API key for
## apps you have and want to make requests to using Media Bot.
## See the Service Checks section below for information about setting the names.
##
## Examples follow. UNCOMMENT (REMOVE #), AT MINIMUM: [[header]], url, api_key
## Setting any application timeout to "-1s" will disable that application.

#[[lidarr]]
#name     = "" # Set a name to enable checks of your service.
#url      = "http://lidarr:8989/"
#api_key  = ""


#[[prowlarr]]
#name     = "" # Set a name to enable checks of your service.
#url      = "http://prowlarr:9696/"
#api_key  = ""


#[[radarr]]
#name      = "" # Set a name to enable checks of your service.
#url       = "http://127.0.0.1:7878/"
#api_key   = ""


#[[readarr]]
#name      = "" # Set a name to enable checks of your service.
#url       = "http://127.0.0.1:8787/"
#api_key   = ""


#[[sonarr]]
#name      = ""  # Set a name to enable checks of your service.
#url       = "http://sonarr:8989/"
#api_key   = ""


# Download Client Configs (below) are used for dashboard state and service checks.

#[[deluge]]
#name     = ""  # Set a name to enable checks of your service.
#url      = "http://deluge:8112/"
#password = ""


#[[qbit]]
#name     = ""  # Set a name to enable checks of your service.
#url      = "http://qbit:8080/"
#user     = ""
#pass     = ""


#[[rtorrent]]
#name     = ""  # Set a name to enable checks of your service.
#url      = "http://rtorrent:5000/"
#user     = ""
#pass     = ""


#[[nzbget]]
#name     = ""  # Set a name to enable checks of your service.
#url      = "http://nzbget:6789/"
#user     = ""
#pass     = ""


#[[sabnzbd]]
#name     = ""  # Set a name to enable checks of this application.
#url      = "http://sabnzbd:8080/"
#api_key  = ""


#################
# Plex Settings #
#################

## Find your token: https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/
##
#[plex]
#url     = "http://localhost:32400/" # Your plex URL
#token   = "" # your plex token; get this from a web inspector

#####################
# Tautulli Settings #
#####################

# Enables email=>username map. Set a name to enable service checks.
# Must uncomment [tautulli], 'api_key' and 'url' at a minimum.

#[tautulli]
#  name    = "" # only set a name to enable service checks.
#  url     = "http://localhost:8181/" # Your Tautulli URL
#  api_key = "" # your tautulli api key; get this from settings

##################
# MySQL Snapshot #
##################

# Enables MySQL process list in snapshot output.
# Adding a name to a server enables TCP service checks.
# Example Grant:
# GRANT PROCESS ON *.* to 'notifiarr'@'localhost'

#[[snapshot.mysql]]
#name = "" # only set a name to enable service checks.
#host = "localhost:3306"
#user = "notifiarr"
#pass = "password"

###################
# Nvidia Snapshot #
###################

# The app will automatically collect Nvidia data if nvidia-smi is present.
# Use the settings below to disable Nvidia GPU collection, or restrict collection to only specific Bus IDs.
# SMI Path is found automatically if left blank. Set it to path to nvidia-smi (nvidia-smi.exe on Windows).

[snapshot.nvidia]
disabled = false
smi_path = ''''''
bus_ids  = []

##################
# Service Checks #
##################

## This application performs service checks on configured services at the specified interval.
## The service states are sent to Notifiarr.com. Failed services generate a notification.
## Setting names on Starr apps (above) enables service checks for that app.
## Setting the Interval to "-1s" (Disabled in UI) will disable service checks on that named instance.
## Use the [[service]] directive to add more service checks. Example below.

[services]
  disabled = false # Setting this to true disables all service checking routines.
  parallel = 1     # How many services to check concurrently. 1 should be enough.
  interval = "10m" # How often to send service states to Notifiarr.com. Minimum = 5m.
  log_file = ''    # Service Check logs go to the app log by default. Change that by setting a services.log file here.

## Uncomment the following section to create a service check on a URL or IP:port.
## You may include as many [[service]] sections as you have services to check.
## Do not add Radarr, Sonarr, Readarr, Prowlarr, or Lidarr here! Add a name to enable their checks.
##
## Example with comments follows.
#[[service]]
#  name     = "MyServer"          # name must be unique
#  type     = "http"              # type can be "http" or "tcp"
#  check    = 'http://127.0.0.1/'  # url for 'http', host/IP:port for 'tcp'
#  expect   = "200"               # return code to expect (for http only)
#  timeout  = "10s"               # how long to wait for tcp or http checks.
#  interval = "5m"                # how often to check this service.

## Another example. Remember to uncomment [[service]] if you use this!
##
#[[service]]
#  name    = "Bazarr"
#  type    = "http"
#  check   = 'http://10.1.1.2:6767/series/'
#  expect  = "200"
#  timeout = "10s"


######################
# File & Log Watcher #
######################

## Tail a log file, regex match lines, and send notifications.
## Example:

#[[watch_file]]
#  path  = '/var/log/system.log'
#  skip  = '''error'''
#  regex = '''[Ee]rror'''
#  poll  = false
#  pipe  = false
#  must_exist = false
#  log_match  = true



###################
# Custom Commands #
###################

## Run and trigger custom commands.
## Commands may have required arguments that can be passed in when the command is run.
## These use the format ({regex}) - a regular expression wrapped by curly braces and parens.
## The example below allows a user to run any combination of ls -la on /usr, /home, or /tmp:
## command = "/bin/ls ({-la|-al|-l|-a}) ({/usr|/home|/tmp})"
##
## Full Example (remove the leading # hashes to use it):

#[[command]]
#  name    = 'some-name-for-logs'
#  command = '/var/log/system.log'
#  shell   = false
#  log     = true
#  notify  = true
#  timeout = "10s"
CFG

    chown -R "$user":"$user" "$app_configdir"
    chmod 600 "$app_configdir/$app_name.conf"
    echo_progress_done "Default config created"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_notifiarr() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    _verbose "Creating backup directory: ${backup_dir}"
    mkdir -p "$backup_dir"

    if [[ -f "${app_dir}/${app_binary}" ]]; then
        _verbose "Backing up binary: ${app_dir}/${app_binary}"
        cp "${app_dir}/${app_binary}" "${backup_dir}/${app_binary}"
        _verbose "Backup complete ($(du -h "${backup_dir}/${app_binary}" | cut -f1))"
    else
        echo_error "Binary not found: ${app_dir}/${app_binary}"
        return 1
    fi
}

# ==============================================================================
# Rollback (restore from backup on failed update)
# ==============================================================================
_rollback_notifiarr() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    echo_error "Update failed, rolling back..."

    if [[ -f "${backup_dir}/${app_binary}" ]]; then
        _verbose "Restoring binary from backup"
        cp "${backup_dir}/${app_binary}" "${app_dir}/${app_binary}"
        chmod +x "${app_dir}/${app_binary}"

        _verbose "Restarting service"
        systemctl restart "$app_servicefile" 2>/dev/null || true

        echo_info "Rollback complete. Previous version restored."
    else
        echo_error "No backup found at ${backup_dir}"
        echo_info "Manual intervention required"
    fi

    rm -rf "$backup_dir"
}

# ==============================================================================
# Update
# ==============================================================================
_update_notifiarr() {
    local full_reinstall="$1"

    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi

    # Full reinstall
    if [[ "$full_reinstall" == "true" ]]; then
        echo_info "Performing full reinstall of ${app_name^}..."
        echo_progress_start "Stopping service"
        systemctl stop "$app_servicefile" 2>/dev/null || true
        echo_progress_done "Service stopped"

        _install_notifiarr

        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"
        echo_success "${app_name^} reinstalled"
        exit 0
    fi

    # Binary-only update (default)
    echo_info "Updating ${app_name^}..."

    echo_progress_start "Backing up current binary"
    if ! _backup_notifiarr; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Downloading latest release"

    local _tmp_download
    _tmp_download=$(mktemp /tmp/notifiarr-XXXXXX.gz)

    case "$(_os_arch)" in
        "amd64") arch='amd64' ;;
        "arm64") arch='arm64' ;;
        *)
            echo_error "Architecture not supported"
            _rollback_notifiarr
            exit 1
            ;;
    esac

    local github_repo="Notifiarr/notifiarr"
    _verbose "Querying GitHub API: https://api.github.com/repos/${github_repo}/releases/latest"

    latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" \
        | grep "$arch" \
        | grep "browser_download_url" \
        | grep "linux.gz" \
        | cut -d\" -f4) || {
        echo_error "Failed to query GitHub"
        _rollback_notifiarr
        exit 1
    }

    if [[ -z "$latest" ]]; then
        echo_error "No matching release found"
        _rollback_notifiarr
        exit 1
    fi

    _verbose "Downloading: ${latest}"
    if ! curl -fsSL "$latest" -o "$_tmp_download" >>"$log" 2>&1; then
        echo_error "Download failed"
        _rollback_notifiarr
        exit 1
    fi
    echo_progress_done "Downloaded"

    echo_progress_start "Installing update"
    if ! gunzip -c "$_tmp_download" >"${app_dir}/${app_binary}" 2>>"$log"; then
        echo_error "Extraction failed"
        rm -f "$_tmp_download"
        _rollback_notifiarr
        exit 1
    fi
    rm -f "$_tmp_download"
    chmod +x "${app_dir}/${app_binary}"
    echo_progress_done "Installed"

    echo_progress_start "Restarting service"
    systemctl start "$app_servicefile"

    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_progress_done "Service running"
        _verbose "Service status: active"
    else
        echo_progress_done "Service may have issues"
        _rollback_notifiarr
        exit 1
    fi

    rm -rf "/tmp/swizzin-update-backups/${app_name}"
    echo_success "${app_name^} updated"
    exit 0
}

_remove_notifiarr() {
    local force="$1"
    if [ "$force" != "--force" ] && [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Ask about purging configuration
    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and disable service
    echo_progress_start "Stopping and disabling ${app_name^} service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/$app_servicefile"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove binary
    echo_progress_start "Removing ${app_name^} binary"
    rm -f "$app_dir/$app_binary"
    echo_progress_done "Binary removed"

    # Remove nginx config
    if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
        echo_progress_start "Removing nginx configuration"
        _remove_nginx_conf "$app_name"
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

    # Remove config directory if purging
    if [ "$purgeconfig" = "true" ]; then
        echo_progress_start "Purging configuration files"
        rm -rf "$app_configdir"
        echo_progress_done "Configuration purged"
        # Remove swizdb entry
        swizdb clear "$app_name/owner" 2>/dev/null || true
    else
        echo_info "Configuration files kept at: $app_configdir"
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
}

_systemd_notifiarr() {
    echo_progress_start "Installing Systemd service"
    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Official chat integration client for Notifiarr.com
After=network.target
Requires=network.target

[Service]
ExecStart=$app_dir/$app_binary -c $app_configdir/$app_name.conf $DAEMON_OPTS
User=${user}
Group=${app_group}
Restart=always
RestartSec=10
Type=simple
SyslogIdentifier=notifiarr
WorkingDirectory=$app_configdir
EnvironmentFile=-$app_configdir/$app_name.env
Environment=DN_API_KEY=${API_KEY}
Environment=DN_URLBASE=/notifiarr
Environment=DN_LOG_FILE=$app_configdir/logs/app.log
Environment=DN_HTTP_LOG=$app_configdir/logs/http.log
Environment=DN_DEBUG_LOG=$app_configdir/logs/debug.log
Environment=DN_SERVICES_LOG_FILE=$app_configdir/logs/services.log
Environment=DN_QUIET=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable --now -q "$app_servicefile"
    sleep 1
    echo_progress_done "${app_name^} service installed and enabled"
}

_nginx_notifiarr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /${app_baseurl} {
			    proxy_pass http://127.0.0.1:${app_port};
			    proxy_set_header Host \$host;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect off;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;
			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /${app_baseurl}/api {
			    auth_basic off;
			    proxy_pass http://127.0.0.1:${app_port};
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
    fi
}

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

# Handle --update flag
if [[ "${1:-}" == "--update" ]]; then
    full_reinstall=false
    for arg in "$@"; do
        case "$arg" in
            --full) full_reinstall=true ;;
        esac
    done
    _update_notifiarr "$full_reinstall"
fi

# Handle --remove flag
if [ "${1:-}" = "--remove" ]; then
    _remove_notifiarr "${2:-}"
fi

# Handle --register-panel flag
if [ "${1:-}" = "--register-panel" ]; then
    if [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "Notifiarr" \
            "/$app_baseurl" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_name^}"
    else
        echo_error "Panel helper not available"
        exit 1
    fi
    exit 0
fi

# Check if already installed
if [ -f "/install/.$app_lockname.lock" ]; then
    echo_info "${app_name^} is already installed"
else
    # Set owner for install
    if [ -n "$NOTIFIARR_OWNER" ]; then
        echo_info "Setting ${app_name^} owner = $NOTIFIARR_OWNER"
        swizdb set "$app_name/owner" "$NOTIFIARR_OWNER"
    fi

    _install_notifiarr
    _systemd_notifiarr
    _nginx_notifiarr
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Notifiarr" \
        "/$app_baseurl" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
echo_info "Access at: https://your-server/${app_baseurl}/"
echo_info "Port: ${app_port}"
