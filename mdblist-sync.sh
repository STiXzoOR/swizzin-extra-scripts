#!/bin/bash
# mdblist-sync installer
# Deploys MDBList auto-sync for Sonarr & Radarr
# Usage: bash mdblist-sync.sh [--remove] [--run] [--status]

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mdblist-sync.py"
SCRIPT_DST="/usr/local/bin/mdblist-sync"
CONFIG_EXAMPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configs/mdblist-sync.conf.example"
CONFIG_DST="/opt/swizzin-extras/mdblist-sync.conf"
STATE_FILE="/opt/swizzin-extras/mdblist-sync.state.json"
LEGACY_DST="/opt/swizzin-extras/mdblist-sync.py"
SERVICE_NAME="mdblist-sync"
LOG_FILE="/var/log/mdblist-sync.log"

# ==============================================================================
# Helpers
# ==============================================================================

echo_info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
echo_ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
echo_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
echo_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# Escape a string for safe use in sed replacement (handles &, |, \)
_sed_escape_value() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

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
# Install
# ==============================================================================

_install() {
    echo_info "Installing MDBList Auto-Sync..."

    # Check that at least one *arr is installed
    local has_radarr=false has_sonarr=false
    for user_dir in /home/*/; do
        [[ -d "$user_dir" ]] || continue
        # Radarr
        for p in "${user_dir}.config/Radarr/config.xml" "${user_dir}.config/radarr-4k/config.xml" "${user_dir}.config/radarr4k/config.xml"; do
            [[ -f "$p" ]] && has_radarr=true && break
        done
        # Sonarr
        for p in "${user_dir}.config/Sonarr/config.xml" "${user_dir}.config/sonarr-4k/config.xml" "${user_dir}.config/sonarr4k/config.xml" "${user_dir}.config/sonarr-anime/config.xml"; do
            [[ -f "$p" ]] && has_sonarr=true && break
        done
    done

    if [[ "$has_radarr" == false && "$has_sonarr" == false ]]; then
        echo_error "Neither Sonarr nor Radarr is installed."
        echo_error "Install at least one before setting up MDBList sync."
        exit 1
    fi

    [[ "$has_radarr" == true ]] && echo_ok "Radarr detected"
    [[ "$has_sonarr" == true ]] && echo_ok "Sonarr detected"
    [[ "$has_radarr" == false ]] && echo_warn "Radarr not found - movie lists will be skipped"
    [[ "$has_sonarr" == false ]] && echo_warn "Sonarr not found - show lists will be skipped"

    # Create directories
    mkdir -p /opt/swizzin-extras
    mkdir -p "$(dirname "$LOG_FILE")"

    # Deploy script
    if [[ ! -f "$SCRIPT_SRC" ]]; then
        echo_error "Source script not found: $SCRIPT_SRC"
        exit 1
    fi
    cp "$SCRIPT_SRC" "$SCRIPT_DST"
    chmod +x "$SCRIPT_DST"
    echo_ok "Script deployed to $SCRIPT_DST"

    # Clean up legacy location
    if [[ -f "$LEGACY_DST" ]]; then
        rm -f "$LEGACY_DST"
        echo_info "Removed legacy script at $LEGACY_DST"
    fi

    # Deploy config template
    if [[ ! -f "$CONFIG_DST" ]]; then
        if [[ ! -f "$CONFIG_EXAMPLE" ]]; then
            echo_error "Config example not found: $CONFIG_EXAMPLE"
            exit 1
        fi
        cp "$CONFIG_EXAMPLE" "$CONFIG_DST"
        chmod 600 "$CONFIG_DST"
        echo_ok "Config template created"
    else
        echo_info "Config already exists, not overwriting: $CONFIG_DST"
    fi

    # --- Interactive configuration ---
    echo ""
    echo_info "=== Configuration ==="
    echo ""

    # Helper: set a config value (value is escaped for sed safety)
    _set_config() {
        local key="$1"
        local value
        value=$(_sed_escape_value "$2")
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_DST"
    }

    # Helper: get current config value
    _get_config() {
        grep -oP "^\s*${1}\s*=\s*\"\K[^\"]+" "$CONFIG_DST" 2>/dev/null || true
    }

    # 1) MDBList API key
    current_key=$(_get_config MDBLIST_API_KEY)
    if [[ -z "$current_key" ]]; then
        echo_info "Get your free MDBList API key from: https://mdblist.com/preferences/"
        echo ""
        read -rp "MDBList API key: " api_key
        if [[ -n "$api_key" ]]; then
            _set_config MDBLIST_API_KEY "$api_key"
            echo_ok "API key saved"
        else
            echo_warn "No API key entered - script won't work without it"
        fi
    else
        echo_ok "API key: already configured"
    fi

    # 2) Discovery settings
    echo ""
    echo_info "--- List Discovery ---"

    read -rp "Minimum likes for a list to be added [50]: " min_likes
    [[ -n "$min_likes" ]] && _set_config MIN_LIKES "$min_likes"

    read -rp "Max movie lists per Radarr instance [15]: " max_movies
    [[ -n "$max_movies" ]] && _set_config MAX_LISTS_MOVIES "$max_movies"

    read -rp "Max show lists per Sonarr instance [15]: " max_shows
    [[ -n "$max_shows" ]] && _set_config MAX_LISTS_SHOWS "$max_shows"

    echo ""
    echo_info "Search terms help discover genre/niche lists beyond the top popular ones"
    echo_info "Examples: trending,netflix,horror,sci-fi,anime,best 2026,4k"
    read -rp "Search terms (comma-separated, or Enter for none): " terms
    [[ -n "$terms" ]] && _set_config SEARCH_TERMS "$terms"

    # 3) Pinned / blocked lists
    echo ""
    echo_info "You can pin specific MDBList list IDs (always included) or block them"
    read -rp "Pinned list IDs (comma-separated, or Enter for none): " pinned
    [[ -n "$pinned" ]] && _set_config PINNED_LISTS "$pinned"

    read -rp "Blocked list IDs (comma-separated, or Enter for none): " blocked
    [[ -n "$blocked" ]] && _set_config BLOCKED_LISTS "$blocked"

    # 4) Radarr settings - auto-detect from running instances
    echo ""
    echo_info "--- Radarr Settings ---"

    # Try to auto-detect Radarr quality profiles and root folders
    _detect_arr_settings() {
        local app_type="$1" # radarr or sonarr
        local config_xml=""

        for user_dir in /home/*/; do
            local user
            user=$(basename "$user_dir")
            local paths=()
            if [[ "$app_type" == "radarr" ]]; then
                paths=("${user_dir}.config/Radarr/config.xml" "${user_dir}.config/radarr-4k/config.xml")
            else
                paths=("${user_dir}.config/Sonarr/config.xml" "${user_dir}.config/sonarr-4k/config.xml" "${user_dir}.config/sonarr-anime/config.xml")
            fi
            for p in "${paths[@]}"; do
                if [[ -f "$p" ]]; then
                    config_xml="$p"
                    break 2
                fi
            done
        done

        if [[ -z "$config_xml" ]]; then
            return 1
        fi

        local port api_key url_base
        port=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse('$config_xml').getroot().findtext('Port',''))" 2>/dev/null || true)
        api_key=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse('$config_xml').getroot().findtext('ApiKey',''))" 2>/dev/null || true)
        url_base=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse('$config_xml').getroot().findtext('UrlBase',''))" 2>/dev/null || true)

        if [[ -z "$port" || -z "$api_key" ]]; then
            return 1
        fi

        local base_url=""
        [[ -n "$url_base" ]] && base_url="/${url_base}"

        # Fetch quality profiles
        local profiles
        profiles=$(curl -s -H "X-Api-Key: $api_key" "http://localhost:${port}${base_url}/api/v3/qualityprofile" 2>/dev/null || true)
        if [[ -n "$profiles" && "$profiles" != "[]" ]]; then
            echo_info "  Available quality profiles:"
            echo "$profiles" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data:
    print(f'    - {p[\"name\"]} (id={p[\"id\"]})')
" 2>/dev/null || true
        fi

        # Fetch root folders
        local folders
        folders=$(curl -s -H "X-Api-Key: $api_key" "http://localhost:${port}${base_url}/api/v3/rootfolder" 2>/dev/null || true)
        if [[ -n "$folders" && "$folders" != "[]" ]]; then
            echo_info "  Available root folders:"
            echo "$folders" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data:
    free_gb = f.get('freeSpace', 0) / (1024**3)
    print(f'    - {f[\"path\"]} ({free_gb:.0f} GB free)')
" 2>/dev/null || true
        fi

        return 0
    }

    if _detect_arr_settings radarr; then
        echo ""
        read -rp "Radarr quality profile name (Enter for auto-detect): " rqp
        [[ -n "$rqp" ]] && _set_config RADARR_QUALITY_PROFILE "$rqp"

        read -rp "Radarr root folder path (Enter for auto-detect): " rrf
        [[ -n "$rrf" ]] && _set_config RADARR_ROOT_FOLDER "$rrf"
    else
        echo_warn "No Radarr instance detected - will auto-detect at runtime"
    fi

    echo ""
    echo_info "Monitor mode: movieOnly (just the movie) or movieAndCollection (+ collections)"
    read -rp "Radarr monitor mode [movieOnly]: " rmon
    [[ -n "$rmon" ]] && _set_config RADARR_MONITOR "$rmon"

    echo ""
    echo_info "Minimum availability: tba, announced, inCinemas, released"
    read -rp "Radarr minimum availability [released]: " ravail
    [[ -n "$ravail" ]] && _set_config RADARR_MIN_AVAILABILITY "$ravail"

    read -rp "Search for movies when added? [true]: " rsearch
    [[ -n "$rsearch" ]] && _set_config RADARR_SEARCH_ON_ADD "$rsearch"

    # 5) Sonarr settings
    echo ""
    echo_info "--- Sonarr Settings ---"

    if _detect_arr_settings sonarr; then
        echo ""
        read -rp "Sonarr quality profile name (Enter for auto-detect): " sqp
        [[ -n "$sqp" ]] && _set_config SONARR_QUALITY_PROFILE "$sqp"

        read -rp "Sonarr root folder path (Enter for auto-detect): " srf
        [[ -n "$srf" ]] && _set_config SONARR_ROOT_FOLDER "$srf"
    else
        echo_warn "No Sonarr instance detected - will auto-detect at runtime"
    fi

    echo ""
    echo_info "Monitor mode: all, future, missing, existing, pilot, firstSeason, latestSeason, none"
    read -rp "Sonarr monitor mode [all]: " smon
    [[ -n "$smon" ]] && _set_config SONARR_MONITOR "$smon"

    echo ""
    echo_info "Series type: standard, daily, anime"
    read -rp "Sonarr series type [standard]: " stype
    [[ -n "$stype" ]] && _set_config SONARR_SERIES_TYPE "$stype"

    read -rp "Search for missing episodes when added? [true]: " ssearch
    [[ -n "$ssearch" ]] && _set_config SONARR_SEARCH_ON_ADD "$ssearch"

    echo ""
    echo_ok "Configuration saved to $CONFIG_DST"

    # Create systemd service
    cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=MDBList Auto-Sync for Sonarr/Radarr
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DST}
Environment=MDBLIST_SYNC_CONFIG=${CONFIG_DST}
Environment=MDBLIST_SYNC_STATE=${STATE_FILE}
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
EOF
    echo_ok "Systemd service created"

    # Create systemd timer (runs daily at 3:00 AM)
    cat >"/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=MDBList Auto-Sync daily timer

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    echo_ok "Systemd timer created (daily at 03:00 +/- 30min jitter)"

    # Create cleanup service + timer (runs weekly)
    cat >"/etc/systemd/system/${SERVICE_NAME}-cleanup.service" <<EOF
[Unit]
Description=MDBList Auto-Sync cleanup stale lists
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DST} --cleanup
Environment=MDBLIST_SYNC_CONFIG=${CONFIG_DST}
Environment=MDBLIST_SYNC_STATE=${STATE_FILE}
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
EOF

    cat >"/etc/systemd/system/${SERVICE_NAME}-cleanup.timer" <<EOF
[Unit]
Description=MDBList Auto-Sync weekly cleanup timer

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    echo_ok "Cleanup timer created (weekly on Sunday at 04:00)"

    # Enable and start timers
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer"
    systemctl enable --now "${SERVICE_NAME}-cleanup.timer"
    echo_ok "Timers enabled and started"

    echo ""
    echo_ok "Installation complete!"
    echo ""
    echo_info "Next steps:"
    echo_info "  1. Test (dry run):  bash $0 --run --dry-run"
    echo_info "  2. Run now:         bash $0 --run"
    echo_info "  3. Check status:    bash $0 --status"
    echo_info "  4. Edit config:     nano $CONFIG_DST"
    echo_info "  5. View logs:       tail -f $LOG_FILE"
    echo ""
    echo_info "Schedule: daily sync at 03:00, weekly cleanup on Sundays at 04:00"
}

# ==============================================================================
# Remove
# ==============================================================================

_remove() {
    echo_info "Removing MDBList Auto-Sync..."

    # Stop and disable timers
    systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
    systemctl stop "${SERVICE_NAME}-cleanup.timer" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}-cleanup.timer" 2>/dev/null || true

    # Remove systemd units
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"
    rm -f "/etc/systemd/system/${SERVICE_NAME}-cleanup.service"
    rm -f "/etc/systemd/system/${SERVICE_NAME}-cleanup.timer"
    systemctl daemon-reload
    echo_ok "Systemd units removed"

    # Remove script (keep config and state for re-install)
    rm -f "$SCRIPT_DST"
    rm -f "$LEGACY_DST"
    echo_ok "Script removed"

    echo_info "Config preserved at: $CONFIG_DST"
    echo_info "State preserved at: $STATE_FILE"
    echo_info "To fully clean up: rm -f $CONFIG_DST $STATE_FILE $LOG_FILE"
    echo ""
    echo_warn "Note: Import lists added to Sonarr/Radarr are NOT removed."
    echo_warn "To clean them up, run --cleanup before removing"

    echo_ok "Removal complete"
}

# ==============================================================================
# Run Now
# ==============================================================================

_run() {
    echo_info "Running MDBList sync now..."
    if [[ ! -f "$SCRIPT_DST" ]]; then
        echo_error "Script not installed. Run: bash $0"
        exit 1
    fi
    MDBLIST_SYNC_CONFIG="$CONFIG_DST" MDBLIST_SYNC_STATE="$STATE_FILE" \
        "$SCRIPT_DST" "$@"
}

# ==============================================================================
# Main
# ==============================================================================

case "${1:-}" in
    --remove)
        _remove
        ;;
    --run)
        shift
        _run "$@"
        ;;
    --status)
        _run --status
        ;;
    *)
        if [[ -f "/etc/systemd/system/${SERVICE_NAME}.timer" ]]; then
            echo_info "Already installed. Updating script..."
            cp "$SCRIPT_SRC" "$SCRIPT_DST"
            chmod +x "$SCRIPT_DST"
            echo_ok "Script updated at $SCRIPT_DST"
            echo_info "Use --run to test, --remove to uninstall"
        else
            _install
        fi
        ;;
esac
