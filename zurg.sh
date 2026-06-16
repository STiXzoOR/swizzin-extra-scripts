#!/bin/bash
set -euo pipefail
# zurg installer
# STiXzoOR 2025
# Usage: bash zurg.sh [--remove [--force]] [--switch-version [free|paid]] [--update [--full] [--latest] [--verbose]] [--register-panel]

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
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

app_name="zurg"

# Get owner from swizdb (needed for both install and remove)
if ! ZURG_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    ZURG_OWNER="$(_get_master_username)"
fi
user="$ZURG_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name}"
app_group="$user"
app_port=9999
app_reqs=("curl" "unzip" "fuse3" "ffmpeg")
app_servicefile="$app_name.service"
app_mount_servicefile="rclone-$app_name.service"
app_dir="/usr/bin"
app_binary="$app_name"
app_lockname="${app_name//-/}"
app_default_mount="/mnt/$app_name"
app_icon_name="placeholder"
app_icon_url=""

if [ ! -d "$swiz_configdir" ]; then
    mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

# Detect free/paid from config file when swizdb has no entry
_detect_zurg_version_from_config() {
    local config_file="$app_configdir/config.yml"
    if [ -f "$config_file" ]; then
        if grep -q 'rclone_enabled: true' "$config_file" 2>/dev/null; then
            echo "paid"
            return 0
        elif grep -q '# Zurg configuration (paid version)' "$config_file" 2>/dev/null; then
            echo "paid"
            return 0
        else
            echo "free"
            return 0
        fi
    fi
    return 1
}

# Zurg version selection
_select_zurg_version() {
    # Check existing version in swizdb
    local existing_version
    existing_version=$(swizdb get "zurg/version" 2>/dev/null) || true

    # Check environment variable - may trigger switch if different
    if [ -n "${ZURG_VERSION:-}" ]; then
        if [[ "$ZURG_VERSION" == "paid" || "$ZURG_VERSION" == "free" ]]; then
            # If env var differs from existing, trigger switch
            if [ -n "$existing_version" ] && [ "$ZURG_VERSION" != "$existing_version" ]; then
                echo_info "ZURG_VERSION=$ZURG_VERSION differs from installed ($existing_version)"
                _switch_version "$ZURG_VERSION" "$existing_version"
                return
            fi
            zurg_version="$ZURG_VERSION"
            echo_info "Using zurg version from ZURG_VERSION: $zurg_version"
            return
        fi
    fi

    # If already installed, check if we're just doing a tag upgrade (not a version switch)
    if [ -n "$existing_version" ] && [ "$switch_mode" != "true" ]; then
        # Normalize ZURG_USE_LATEST_TAG for comparison
        local _use_latest="${ZURG_USE_LATEST_TAG:-}"
        _use_latest="${_use_latest,,}" # lowercase

        # If tag specified, keep same version (free/paid) - no need to prompt
        if [[ "$_use_latest" == "true" || "$_use_latest" == "1" || "$_use_latest" == "yes" ]] || [ -n "${ZURG_VERSION_TAG:-}" ]; then
            zurg_version="$existing_version"
            echo_info "Tag upgrade requested - keeping $existing_version version"
            return
        fi

        # Otherwise offer to switch versions
        local other_version
        if [ "$existing_version" = "free" ]; then
            other_version="paid"
        else
            other_version="free"
        fi

        echo_info "Currently running zurg $existing_version version"
        if ask "Would you like to switch to $other_version version?" N; then
            _switch_version "$other_version" "$existing_version"
            return
        fi

        zurg_version="$existing_version"
        echo_info "Keeping $existing_version version"
        return
    fi

    # Fresh install - prompt for version
    echo_info "Zurg has two versions:"
    echo_info "  - free: Public repo (debridmediamanager/zurg-testing)"
    echo_info "  - paid: Private repo for GitHub sponsors (debridmediamanager/zurg)"
    echo ""
    if ask "Do you have the paid/sponsor version of Zurg?" N; then
        zurg_version="paid"
    else
        zurg_version="free"
    fi
}

# GitHub authentication for paid version
_get_github_token() {
    # Check environment variable first
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        local token_preview="${GITHUB_TOKEN:0:4}...${GITHUB_TOKEN: -4}"
        echo_info "Using GitHub token from GITHUB_TOKEN environment variable ($token_preview)"
        github_token="$GITHUB_TOKEN"
        return 0
    fi

    # Check if gh CLI is available and authenticated
    if command -v gh &>/dev/null; then
        if gh auth status &>/dev/null; then
            echo_info "Using GitHub CLI authentication"
            github_token="gh_cli"
            return 0
        fi
    fi

    # Prompt for token
    echo_info "GitHub authentication required to access paid zurg repo"
    echo_info "Create a token at: https://github.com/settings/tokens"
    echo_info "Required scope: repo (to access private repositories)"
    echo ""
    echo_query "Enter your GitHub Personal Access Token" ""
    read -r github_token </dev/tty
    echo "" >/dev/tty

    if [ -z "$github_token" ]; then
        echo_error "GitHub token is required for paid version"
        return 1
    fi

    # Test the token
    echo_progress_start "Verifying GitHub access"
    local test_response
    test_response=$(curl -sL --config <(printf 'header = "Authorization: token %s"' "$github_token") \
        "https://api.github.com/repos/debridmediamanager/zurg" 2>&1)

    if echo "$test_response" | grep -q '"id"'; then
        echo_progress_done "GitHub access verified"
        return 0
    else
        echo_error "Cannot access paid zurg repo. Make sure you:"
        echo_error "  1. Have sponsored debridmediamanager"
        echo_error "  2. Used the correct GitHub account"
        echo_error "  3. Token has 'repo' scope"
        return 1
    fi
}

# Return benchmark-optimized rclone settings
# These values are from zurg's performance testing (replaces old RAM-based profiles)
# See: https://github.com/debridmediamanager/zurg changelog
_get_rclone_settings() {
    # Benchmark-optimized defaults:
    # --buffer-size: 256M (was 32M)
    # --vfs-read-chunk-size: off (disabling chunking improves throughput)
    # --vfs-read-chunk-size-limit: 512M (was 64M)
    # --vfs-read-ahead: 1G (new)
    # --max-read-ahead: 1M (new)
    # --vfs-read-wait: 5ms (was 75ms - critical: 75ms=~28Mbps, 5ms=~533Mbps)
    # --async-read: false (sync reads perform better)
    # --vfs-cache-poll-interval: 1m (was 10m)
    echo "256M off 512M"
}

# Install latest rclone from official script
_install_rclone() {
    if command -v rclone &>/dev/null; then
        local current_version
        current_version=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
        echo_info "rclone $current_version already installed"
        return 0
    fi

    echo_progress_start "Installing rclone"
    # The official install script may return non-zero if already latest
    curl -fsSL https://rclone.org/install.sh | bash >>"$log" 2>&1 || true

    # Verify rclone is now available
    if command -v rclone &>/dev/null; then
        echo_progress_done "rclone installed: $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
    else
        echo_error "Failed to install rclone"
        exit 1
    fi
}

# Prompt for mount point or use default/env
_get_mount_point() {
    # Skip if already set (e.g., from migration)
    if [ -n "${app_mount_point:-}" ]; then
        echo_info "Using mount point: $app_mount_point"
        return
    fi

    # Check environment variable first
    if [ -n "${ZURG_MOUNT_POINT:-}" ]; then
        echo_info "Using mount point from ZURG_MOUNT_POINT: $ZURG_MOUNT_POINT"
        app_mount_point="$ZURG_MOUNT_POINT"
        return
    fi

    # Check existing config in swizdb
    local existing_mount
    existing_mount=$(swizdb get "zurg/mount_point" 2>/dev/null) || true

    local default_mount="${existing_mount:-$app_default_mount}"

    echo_query "Enter zurg mount point" "[$default_mount]"
    read -r input_mount </dev/tty

    if [ -z "$input_mount" ]; then
        app_mount_point="$default_mount"
    else
        # Validate absolute path
        if [[ ! "$input_mount" = /* ]]; then
            echo_error "Mount point must be an absolute path (start with /)"
            exit 1
        fi
        app_mount_point="$input_mount"
    fi

    echo_info "Using mount point: $app_mount_point"
}

# Update decypharr config if installed
_update_decypharr_config() {
    local mount_point="$1"
    local api_key="$2"
    local decypharr_config="/home/$user/.config/Decypharr/config.json"

    [ -f /install/.decypharr.lock ] || return 0
    [ -f "$decypharr_config" ] || return 0

    echo_progress_start "Updating Decypharr configuration"

    # Update realdebrid folder path and download_folder using jq if available, else warn
    local mount_parent
    mount_parent=$(dirname "$mount_point")

    if command -v jq >/dev/null 2>&1; then
        local tmp_config
        tmp_config=$(mktemp)
        jq --arg folder "${mount_point}/__all__/" \
            --arg key "$api_key" \
            --arg dl_folder "${mount_parent}/symlinks/downloads" '
			.debrids = [.debrids[] | if .name == "realdebrid" then .folder = $folder | .api_key = $key else . end]
			| .qbittorrent.download_folder = $dl_folder
		' "$decypharr_config" >"$tmp_config" 2>/dev/null && mv "$tmp_config" "$decypharr_config"
        chown "$user":"$user" "$decypharr_config"
        chmod 600 "$decypharr_config"
    else
        # Fallback: just log a warning
        echo_warn "jq not installed - please manually update Decypharr config"
        echo_warn "Set realdebrid folder to: ${mount_point}/__all__/"
        echo_warn "Set qbittorrent download_folder to: ${mount_parent}/symlinks/downloads"
        echo_progress_done "Decypharr config needs manual update"
        return
    fi

    # Restart decypharr
    if systemctl is-active --quiet decypharr 2>/dev/null; then
        systemctl restart decypharr
    fi

    echo_progress_done "Decypharr configuration updated"
}

# Migrate config values from existing installation
# Sets: RD_TOKEN, app_port, app_mount_point (global variables)
_migrate_config() {
    local config_file="$app_configdir/config.yml"

    if [ ! -f "$config_file" ]; then
        echo_warn "No existing config found, cannot migrate"
        return 1
    fi

    echo_progress_start "Migrating configuration"

    # Extract token
    if grep -qE '^token: .+' "$config_file" 2>/dev/null; then
        RD_TOKEN=$(grep -E '^token: ' "$config_file" | sed 's/token: //')
    fi

    # Extract port
    local config_port
    config_port=$(grep -E '^port: ' "$config_file" | sed 's/port: //' | tr -d ' ')
    if [ -n "$config_port" ]; then
        app_port="$config_port"
    fi

    # Extract mount point (from config for paid, swizdb for free)
    local config_mount
    config_mount=$(grep -E '^mount_path: ' "$config_file" | sed 's/mount_path: //' | tr -d ' ')
    if [ -n "$config_mount" ]; then
        app_mount_point="$config_mount"
    elif app_mount_point=$(swizdb get "zurg/mount_point" 2>/dev/null); then
        : # Got it from swizdb
    else
        app_mount_point="$app_default_mount"
    fi

    local token_display="***${RD_TOKEN: -4}"
    echo_progress_done "Migrated: token $token_display, port $app_port, mount $app_mount_point"
    return 0
}

# Clean up version-specific artifacts when switching versions
# Args: $1 = old_version (free|paid)
_cleanup_version_artifacts() {
    local old_version="$1"
    local mount_point

    # Get mount point from swizdb or use default
    mount_point=$(swizdb get "zurg/mount_point" 2>/dev/null) || mount_point="$app_default_mount"

    echo_info "Cleaning up $old_version version artifacts..."

    # Stop services first
    if [ -f "/etc/systemd/system/$app_mount_servicefile" ]; then
        echo_progress_start "Stopping rclone mount service"
        systemctl stop "$app_mount_servicefile" 2>/dev/null || true
        echo_progress_done "Rclone mount service stopped"
    fi

    echo_progress_start "Stopping zurg service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Zurg service stopped"

    # Unmount if mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        echo_progress_start "Unmounting $mount_point"
        fusermount -uz "$mount_point" 2>/dev/null || umount -f "$mount_point" 2>/dev/null || true
        echo_progress_done "Unmounted"
    fi

    if [ "$old_version" = "free" ]; then
        # Clean up free version artifacts
        echo_progress_start "Removing free version artifacts"

        # Remove rclone-zurg service
        if [ -f "/etc/systemd/system/$app_mount_servicefile" ]; then
            systemctl disable "$app_mount_servicefile" 2>/dev/null || true
            rm -f "/etc/systemd/system/$app_mount_servicefile"
        fi

        # Clear free version cache
        local free_cache="/home/$user/.cache/rclone/vfs/zurg"
        if [ -d "$free_cache" ]; then
            local cache_size
            cache_size=$(du -sh "$free_cache" 2>/dev/null | cut -f1) || cache_size="unknown"
            rm -rf "$free_cache"
            echo_info "Cleared free version cache ($cache_size freed)"
        fi

        # Remove zurg entry from rclone.conf (keep other remotes)
        local rclone_conf="/home/$user/.config/rclone/rclone.conf"
        if [ -f "$rclone_conf" ] && grep -q '^\[zurg\]' "$rclone_conf"; then
            # Remove [zurg] section
            sed -i '/^\[zurg\]/,/^\[/{/^\[zurg\]/d;/^\[/!d}' "$rclone_conf"
            # Clean up empty file
            if [ ! -s "$rclone_conf" ]; then
                rm -f "$rclone_conf"
            fi
        fi

        echo_progress_done "Free version artifacts removed"

    elif [ "$old_version" = "paid" ]; then
        # Clean up paid version artifacts
        echo_progress_start "Removing paid version artifacts"

        # Clear paid version cache
        local paid_cache="$app_configdir/data/rclone-cache"
        if [ -d "$paid_cache" ]; then
            local cache_size
            cache_size=$(du -sh "$paid_cache" 2>/dev/null | cut -f1) || cache_size="unknown"
            rm -rf "$paid_cache"
            echo_info "Cleared paid version cache ($cache_size freed)"
        fi

        # Remove internal rclone.conf
        rm -f "$app_configdir/data/rclone.conf" 2>/dev/null || true

        echo_progress_done "Paid version artifacts removed"
    fi

    systemctl daemon-reload
}

# Handle version switch
# Args: $1 = target_version (free|paid), $2 = current_version
_switch_version() {
    local target_version="$1"
    local current_version="$2"

    echo_info "Switching zurg from $current_version to $target_version..."

    # For paid version, verify GitHub auth BEFORE making any changes
    if [ "$target_version" = "paid" ]; then
        if ! _get_github_token; then
            echo_error "GitHub authentication failed. Cannot switch to paid version."
            exit 1
        fi
        echo_info "GitHub access verified"
    fi

    # Migrate existing config values
    if ! _migrate_config; then
        echo_error "Failed to migrate configuration"
        exit 1
    fi

    # Clean up old version artifacts
    _cleanup_version_artifacts "$current_version"

    # Set the target version for install
    zurg_version="$target_version"

    echo_info "Proceeding with $target_version version installation..."
}

_install_zurg() {
    if [ ! -d "$app_configdir" ]; then
        mkdir -p "$app_configdir"
    fi
    chown -R "$user":"$user" "$app_configdir"

    apt_install "${app_reqs[@]}"
    _install_rclone

    # Select zurg version (free/paid)
    _select_zurg_version

    # For paid version, get GitHub authentication (skip if already authenticated from switch)
    if [ "$zurg_version" = "paid" ] && [ -z "$github_token" ]; then
        if ! _get_github_token; then
            echo_error "GitHub authentication failed for paid version."
            echo_error "Please ensure GITHUB_TOKEN is set or re-run with correct token."
            echo_info "To install free version instead, set ZURG_VERSION=free"
            exit 1
        fi
    fi

    echo_info "Installing zurg $zurg_version version"

    # Prompt for Real-Debrid token if not already configured
    echo_info "Checking for Real-Debrid API token"
    if [ ! -f "$app_configdir/config.yml" ] || ! grep -qE '^token: .+' "$app_configdir/config.yml" 2>/dev/null; then
        # Check for environment variable first
        if [ -n "${RD_TOKEN:-}" ]; then
            echo_info "Using token from RD_TOKEN environment variable"
        else
            echo_query "Paste your Real-Debrid API token" "from https://real-debrid.com/apitoken"
            read -r RD_TOKEN </dev/tty

            if [ -z "$RD_TOKEN" ]; then
                echo_error "Real-Debrid API token is required. Set RD_TOKEN or provide interactively. Cannot continue!"
                exit 1
            fi
        fi
    else
        echo_info "Existing token found in config"
        RD_TOKEN=$(grep -E '^token: ' "$app_configdir/config.yml" | sed 's/token: //')
    fi

    case "$(_os_arch)" in
        "amd64") arch='linux-amd64' ;;
        "arm64") arch="linux-arm64" ;;
        "armhf") arch="linux-arm-6" ;;
        *)
            echo_error "Arch not supported"
            exit 1
            ;;
    esac

    # Set repo based on version
    if [ "$zurg_version" = "paid" ]; then
        zurg_repo="debridmediamanager/zurg"
    else
        zurg_repo="debridmediamanager/zurg-testing"
    fi

    # Determine which version to download
    local release_endpoint
    local version_tag=""

    # Normalize ZURG_USE_LATEST_TAG to lowercase for comparison
    local use_latest_tag="${ZURG_USE_LATEST_TAG:-}"
    use_latest_tag="${use_latest_tag,,}" # lowercase

    if [ -n "${ZURG_VERSION_TAG:-}" ]; then
        # Use specific tag provided by user
        version_tag="$ZURG_VERSION_TAG"
        release_endpoint="repos/$zurg_repo/releases/tags/$version_tag"
        echo_info "Using specific version tag: $version_tag"
    elif [[ "$use_latest_tag" == "true" || "$use_latest_tag" == "1" || "$use_latest_tag" == "yes" ]]; then
        # Use /releases endpoint (returns in reverse chronological order, includes prereleases)
        # This is better than /tags which returns alphabetically
        release_endpoint="repos/$zurg_repo/releases?per_page=1"
    else
        # Use /releases/latest (only returns latest non-prerelease)
        release_endpoint="repos/$zurg_repo/releases/latest"
    fi

    # Check if endpoint returns array (releases?per_page=1) or object (releases/latest, releases/tags/X)
    local is_array_response="false"
    if [[ "$release_endpoint" == *"per_page="* ]]; then
        is_array_response="true"
    fi

    local _tmp_download _tmp_extract
    _tmp_download=$(mktemp /tmp/zurg-XXXXXX.zip)
    _tmp_extract=$(mktemp -d /tmp/zurg-extract-XXXXXX)

    echo_progress_start "Downloading $zurg_version release"

    # Download release
    if [ "$zurg_version" = "paid" ]; then
        # Paid version requires authentication
        if [ "$github_token" = "gh_cli" ]; then
            # Use gh CLI
            local release_info
            release_info=$(gh api "$release_endpoint" 2>>"$log") || {
                echo_error "Failed to query GitHub for release"
                exit 1
            }

            # Handle array response
            if [ "$is_array_response" = "true" ]; then
                release_info=$(echo "$release_info" | jq '.[0]')
            fi

            local tag_name
            tag_name=$(echo "$release_info" | jq -r '.tag_name')
            echo_info "Found release: $tag_name"

            latest=$(echo "$release_info" | jq -r "[.assets[] | select(.name | contains(\"$arch\"))] | first | .url")
            latest=$(echo "$latest" | tr -d '[:space:]')

            if [ -z "$latest" ] || [ "$latest" = "null" ]; then
                echo_error "Could not find release asset for $arch"
                exit 1
            fi

            if ! gh api "$latest" -H "Accept: application/octet-stream" >"$_tmp_download" 2>>"$log"; then
                echo_error "Download failed, exiting"
                exit 1
            fi
        else
            # Use token - must use asset API URL, not browser_download_url for private repos
            local release_json
            release_json=$(curl -sL --config <(printf 'header = "Authorization: token %s"' "$github_token") \
                "https://api.github.com/$release_endpoint") || {
                echo_error "Failed to query GitHub for release"
                exit 1
            }

            # Handle array response - extract first element
            if [ "$is_array_response" = "true" ]; then
                if command -v jq &>/dev/null; then
                    release_json=$(echo "$release_json" | jq '.[0]')
                elif command -v python3 &>/dev/null; then
                    release_json=$(echo "$release_json" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)[0]))")
                else
                    echo_error "jq or python3 required to parse array response"
                    exit 1
                fi
            fi

            # Show which version we're downloading
            local tag_name
            if command -v jq &>/dev/null; then
                tag_name=$(echo "$release_json" | jq -r '.tag_name')
            else
                tag_name=$(echo "$release_json" | grep -o '"tag_name"[^,]*' | cut -d'"' -f4)
            fi
            echo_info "Found release: $tag_name"

            # Get the asset API URL using jq if available, fallback to python
            # Use 'first' to ensure we only get one URL if multiple assets match
            if command -v jq &>/dev/null; then
                latest=$(echo "$release_json" | jq -r "[.assets[] | select(.name | contains(\"$arch\"))] | first | .url")
            else
                # Fallback: parse JSON with Python if available
                if command -v python3 &>/dev/null; then
                    latest=$(echo "$release_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((a['url'] for a in d['assets'] if '$arch' in a['name']), ''))")
                else
                    echo_error "jq or python3 required to parse GitHub API response"
                    exit 1
                fi
            fi

            # Trim whitespace
            latest=$(echo "$latest" | tr -d '[:space:]')

            if [ -z "$latest" ] || [ "$latest" = "null" ]; then
                echo_error "Could not find release asset for $arch"
                exit 1
            fi

            if ! curl --config <(printf 'header = "Authorization: token %s"\nheader = "Accept: application/octet-stream"' "$github_token") \
                "$latest" -L -o "$_tmp_download" >>"$log" 2>&1; then
                echo_error "Download failed, exiting"
                exit 1
            fi
        fi
    else
        # Free version - no auth needed
        local release_json
        release_json=$(curl -sL "https://api.github.com/$release_endpoint") || {
            echo_error "Failed to query GitHub for release"
            exit 1
        }

        # Handle array response - extract first element
        if [ "$is_array_response" = "true" ]; then
            if command -v jq &>/dev/null; then
                release_json=$(echo "$release_json" | jq '.[0]')
            elif command -v python3 &>/dev/null; then
                release_json=$(echo "$release_json" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)[0]))")
            else
                # Fallback: use grep to find first tag_name (less reliable but works)
                : # Continue with full array, grep will find first match
            fi
        fi

        # Show which version we're downloading
        local tag_name
        if command -v jq &>/dev/null; then
            tag_name=$(echo "$release_json" | jq -r '.tag_name')
        else
            tag_name=$(echo "$release_json" | grep -o '"tag_name"[^,]*' | head -1 | cut -d'"' -f4)
        fi
        echo_info "Found release: $tag_name"

        if command -v jq &>/dev/null; then
            latest=$(echo "$release_json" | jq -r ".assets[] | select(.name | contains(\"$arch\")) | .browser_download_url")
        else
            latest=$(echo "$release_json" | grep "browser_download_url" | grep "$arch" | head -1 | cut -d \" -f4)
        fi

        if [ -z "$latest" ]; then
            echo_error "Could not find release asset for $arch"
            exit 1
        fi

        if ! curl "$latest" -L -o "$_tmp_download" >>"$log" 2>&1; then
            echo_error "Download failed, exiting"
            exit 1
        fi
    fi
    echo_progress_done "Archive downloaded"

    echo_progress_start "Extracting archive"

    unzip -o "$_tmp_download" -d "$_tmp_extract" >>"$log" 2>&1 || {
        echo_error "Failed to extract"
        exit 1
    }
    mv "$_tmp_extract/$app_binary" "$app_dir/$app_binary"
    rm -rf "$_tmp_download" "$_tmp_extract"
    chmod +x "$app_dir/$app_binary"
    echo_progress_done "Archive extracted"

    echo_progress_start "Creating configuration"

    # Get user UID/GID for rclone mount
    local user_uid
    local user_gid
    user_uid=$(id -u "$user")
    user_gid=$(id -g "$user")

    # Create config.yml based on version
    if [ "$zurg_version" = "paid" ]; then
        # Paid version config (newer format with internal rclone)
        cat >"$app_configdir/config.yml" <<CFG
# Zurg configuration (paid version)
# Documentation: https://github.com/debridmediamanager/zurg

zurg: v1
token: "${RD_TOKEN}"

# Network & Server Configuration
host: "127.0.0.1"
port: ${app_port}

# Performance & Rate Limits
api_rate_limit_per_minute: 250
torrents_rate_limit_per_minute: 75
api_timeout_secs: 60
download_timeout_secs: 15

# File Management
enable_repair: true
restrict_repair_to_cached: false
retain_folder_name_extension: false
retain_rd_torrent_name: false

# Scheduling & Updates
check_for_changes_every_secs: 15
repair_every_mins: 60

# Media Analysis
auto_analyze_new_torrents: true
cache_network_test_results: true

# Binary paths
# Use system binaries instead of zurg's auto-downloaded static builds
# System ffprobe is preferred (ffbinaries.com static builds segfault on URL probing)
ffprobe_binary: /usr/bin/ffprobe
rclone_binary: /usr/bin/rclone

# Rclone Management
# Zurg applies benchmark-optimized defaults automatically
# See: https://github.com/debridmediamanager/zurg for rclone flag documentation
rclone_enabled: true
mount_path: ${app_mount_point}
rclone_extra_args:
  - "--allow-other"

# Directory definitions
directories:
  torrents:
    group_order: 10
    group: media
    filters:
      - regex: /.*/
CFG
    else
        # Free version config (older format)
        cat >"$app_configdir/config.yml" <<CFG
# Zurg configuration (free version)
# Documentation: https://github.com/debridmediamanager/zurg-testing

zurg: v1
token: "${RD_TOKEN}"

# Network & Server Configuration
host: "127.0.0.1"
port: ${app_port}

# Performance & Rate Limits
api_rate_limit_per_minute: 250
torrents_rate_limit_per_minute: 75
concurrent_workers: 32
download_timeout_secs: 15

# File Management
enable_repair: true
auto_delete_rar_torrents: false
retain_folder_name_extension: false
retain_rd_torrent_name: false

# Scheduling & Updates
check_for_changes_every_secs: 15
repair_every_mins: 60

# Media Analysis
cache_network_test_results: true

# Directory definitions
directories:
  torrents:
    group_order: 10
    group: media
    filters:
      - regex: /.*/
CFG
    fi

    # Create rclone config for free version only
    # Paid version with rclone_enabled uses zurg's internal rclone config at data/rclone.conf
    if [ "$zurg_version" = "free" ]; then
        local rclone_configdir="/home/$user/.config/rclone"
        if [ ! -d "$rclone_configdir" ]; then
            mkdir -p "$rclone_configdir"
        fi

        cat >"$rclone_configdir/rclone.conf" <<RCLONE
[zurg]
type = webdav
url = http://127.0.0.1:${app_port}/dav
vendor = other
pacer_min_sleep = 0
RCLONE

        chown -R "$user":"$user" "$rclone_configdir"
        chmod 600 "$rclone_configdir/rclone.conf"
    fi

    chown -R "$user":"$user" "$app_configdir"
    chmod 600 "$app_configdir/config.yml"

    # Create mount point
    if [ ! -d "$app_mount_point" ]; then
        mkdir -p "$app_mount_point"
    fi
    chown "$user":"$user" "$app_mount_point"

    echo_progress_done "Configuration created"
}

_remove_zurg() {
    local force="$1"
    if [ "$force" != "--force" ] && [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Get mount point from swizdb (needed for unmounting)
    app_mount_point=$(swizdb get "zurg/mount_point" 2>/dev/null) || app_mount_point="$app_default_mount"

    # Ask about purging configuration
    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and disable rclone mount service if it exists (free version only)
    if [ -f "/etc/systemd/system/$app_mount_servicefile" ]; then
        echo_progress_start "Stopping and disabling rclone mount service"
        systemctl stop "$app_mount_servicefile" 2>/dev/null || true
        systemctl disable "$app_mount_servicefile" 2>/dev/null || true
        rm -f "/etc/systemd/system/$app_mount_servicefile"
        echo_progress_done "Rclone mount service removed"
    fi

    # Unmount if still mounted (for both versions)
    if mountpoint -q "$app_mount_point" 2>/dev/null; then
        echo_progress_start "Unmounting $app_mount_point"
        fusermount -uz "$app_mount_point" 2>/dev/null || umount -f "$app_mount_point" 2>/dev/null || true
        echo_progress_done "Mount point unmounted"
    fi

    # Stop and disable zurg service
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

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Remove nginx config
    if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/$app_name.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove config directory if purging
    if [ "$purgeconfig" = "true" ]; then
        echo_progress_start "Purging configuration files"
        rm -rf "$app_configdir"
        echo_progress_done "Configuration purged"
        # Remove swizdb entries
        swizdb clear "$app_name/owner" 2>/dev/null || true
        swizdb clear "zurg/mount_point" 2>/dev/null || true
        swizdb clear "zurg/api_key" 2>/dev/null || true
        swizdb clear "zurg/version" 2>/dev/null || true
    else
        echo_info "Configuration files kept at: $app_configdir"
    fi

    # Remove mount point
    if [ -d "$app_mount_point" ]; then
        rmdir "$app_mount_point" 2>/dev/null || true
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
}

_systemd_zurg() {
    echo_progress_start "Installing Systemd services"

    # Main zurg service
    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Real-Debrid WebDAV server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_configdir
ExecStart=$app_dir/$app_binary --config $app_configdir/config.yml
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

    # For free version, create separate rclone mount service
    # Paid version uses zurg's internal rclone management
    if [ "$zurg_version" = "free" ]; then
        # Get benchmark-optimized rclone settings
        local rclone_settings
        rclone_settings=$(_get_rclone_settings)
        local buffer_size vfs_chunk_size vfs_chunk_limit
        read -r buffer_size vfs_chunk_size vfs_chunk_limit <<<"$rclone_settings"

        cat >"/etc/systemd/system/$app_mount_servicefile" <<EOF
[Unit]
Description=Rclone mount for ${app_name^}
After=${app_servicefile}
Requires=${app_servicefile}

[Service]
Type=notify
User=${user}
Group=${app_group}
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/rclone mount zurg: $app_mount_point \\
    --config /home/${user}/.config/rclone/rclone.conf \\
    --read-only \\
    --no-modtime \\
    --no-checksum \\
    --poll-interval 0 \\
    --dir-cache-time 15s \\
    --attr-timeout 15s \\
    --vfs-read-wait 5ms \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 256G \\
    --vfs-cache-max-age 72h \\
    --vfs-cache-poll-interval 1m \\
    --buffer-size ${buffer_size} \\
    --vfs-read-chunk-size ${vfs_chunk_size} \\
    --vfs-read-chunk-size-limit ${vfs_chunk_limit} \\
    --vfs-read-ahead 1G \\
    --max-read-ahead 1M \\
    --async-read=false \\
    --allow-other \\
    --uid $(id -u "$user") \\
    --gid $(id -g "$user") \\
    -v
ExecStop=/bin/fusermount -uz $app_mount_point
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    fi

    # Ensure allow_other is enabled in fuse.conf
    if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
        echo "user_allow_other" >>/etc/fuse.conf
    fi

    systemctl -q daemon-reload
    systemctl enable --now -q "$app_servicefile"

    # Only enable rclone mount service for free version
    if [ "$zurg_version" = "free" ]; then
        sleep 2
        systemctl enable --now -q "$app_mount_servicefile"
    fi
    sleep 1

    echo_progress_done "${app_name^} services installed and enabled"
    echo_info "${app_name^} WebDAV running on http://127.0.0.1:$app_port"
    echo_info "Real-Debrid content mounted at $app_mount_point"
}

_nginx_zurg() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_name {
			    return 301 /$app_name/;
			}

			location ^~ /$app_name/ {
			    proxy_pass http://127.0.0.1:$app_port/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Rewrite URLs in responses (zurg has no base_url support)
			    sub_filter_once off;
			    sub_filter_types text/css text/javascript application/javascript application/json;
			    sub_filter 'href="/' 'href="/$app_name/';
			    sub_filter 'src="/' 'src="/$app_name/';
			    sub_filter 'action="/' 'action="/$app_name/';
			    sub_filter 'url(/' 'url(/$app_name/';
			    sub_filter '"/api/' '"/$app_name/api/';
			    sub_filter "'/api/" "'/$app_name/api/";
			    sub_filter 'fetch("/' 'fetch("/$app_name/';
			    sub_filter "fetch('/" "fetch('/$app_name/";

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
    fi
}

_upgrade_binary_zurg() {
    echo_info "Updating zurg binary..."

    # Read version from swizdb, fall back to config file detection
    local zurg_version
    zurg_version=$(swizdb get "zurg/version" 2>/dev/null) || true
    if [ -z "$zurg_version" ]; then
        zurg_version=$(_detect_zurg_version_from_config) || true
        if [ -n "$zurg_version" ]; then
            echo_info "Recovered version ($zurg_version) from config file, saving to swizdb"
            swizdb set "zurg/version" "$zurg_version"
        else
            echo_error "Cannot determine zurg version. Reinstall to fix."
            exit 1
        fi
    fi

    _verbose "Detected installed version: $zurg_version"

    # For paid version, get GitHub authentication
    local github_token=""
    if [ "$zurg_version" = "paid" ]; then
        _verbose "Paid version detected, authenticating with GitHub..."
        if ! _get_github_token; then
            echo_error "GitHub authentication failed for paid version."
            exit 1
        fi
    fi

    # Detect architecture
    local arch
    case "$(_os_arch)" in
        "amd64") arch='linux-amd64' ;;
        "arm64") arch="linux-arm64" ;;
        "armhf") arch="linux-arm-6" ;;
        *)
            echo_error "Arch not supported"
            exit 1
            ;;
    esac

    _verbose "Detected architecture: $arch"

    # Set repo based on version
    local zurg_repo
    if [ "$zurg_version" = "paid" ]; then
        zurg_repo="debridmediamanager/zurg"
    else
        zurg_repo="debridmediamanager/zurg-testing"
    fi

    _verbose "Using repository: $zurg_repo"

    # Determine which release to download
    local release_endpoint
    local use_latest_tag="${ZURG_USE_LATEST_TAG:-}"
    use_latest_tag="${use_latest_tag,,}"

    if [ -n "${ZURG_VERSION_TAG:-}" ]; then
        release_endpoint="repos/$zurg_repo/releases/tags/$ZURG_VERSION_TAG"
        echo_info "Using specific version tag: $ZURG_VERSION_TAG"
    elif [[ "$use_latest_tag" == "true" || "$use_latest_tag" == "1" || "$use_latest_tag" == "yes" ]]; then
        release_endpoint="repos/$zurg_repo/releases?per_page=1"
        _verbose "Using latest tag endpoint (includes prereleases)"
    else
        release_endpoint="repos/$zurg_repo/releases/latest"
        _verbose "Using latest stable release endpoint"
    fi

    local is_array_response="false"
    if [[ "$release_endpoint" == *"per_page="* ]]; then
        is_array_response="true"
    fi

    local _tmp_download _tmp_extract
    _tmp_download=$(mktemp /tmp/zurg-XXXXXX.zip)
    _tmp_extract=$(mktemp -d /tmp/zurg-extract-XXXXXX)

    _verbose "Querying GitHub API: $release_endpoint"
    echo_progress_start "Downloading $zurg_version release"

    # Download release
    if [ "$zurg_version" = "paid" ]; then
        if [ "$github_token" = "gh_cli" ]; then
            _verbose "Using gh CLI for authentication"
            local release_info
            release_info=$(gh api "$release_endpoint" 2>>"$log") || {
                echo_error "Failed to query GitHub for release"
                exit 1
            }
            if [ "$is_array_response" = "true" ]; then
                release_info=$(echo "$release_info" | jq '.[0]')
            fi

            local tag_name
            tag_name=$(echo "$release_info" | jq -r '.tag_name')
            echo_info "Found release: $tag_name"

            latest=$(echo "$release_info" | jq -r "[.assets[] | select(.name | contains(\"$arch\"))] | first | .url")
            latest=$(echo "$latest" | tr -d '[:space:]')

            if [ -z "$latest" ] || [ "$latest" = "null" ]; then
                echo_error "Could not find release asset for $arch"
                exit 1
            fi

            _verbose "Downloading asset from: $latest"
            if ! gh api "$latest" -H "Accept: application/octet-stream" >"$_tmp_download" 2>>"$log"; then
                echo_error "Download failed, exiting"
                exit 1
            fi
        else
            _verbose "Using token-based authentication"
            local release_json
            release_json=$(curl -sL --config <(printf 'header = "Authorization: token %s"' "$github_token") \
                "https://api.github.com/$release_endpoint") || {
                echo_error "Failed to query GitHub for release"
                exit 1
            }
            if [ "$is_array_response" = "true" ]; then
                if command -v jq &>/dev/null; then
                    release_json=$(echo "$release_json" | jq '.[0]')
                elif command -v python3 &>/dev/null; then
                    release_json=$(echo "$release_json" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)[0]))")
                else
                    echo_error "jq or python3 required to parse array response"
                    exit 1
                fi
            fi

            local tag_name
            if command -v jq &>/dev/null; then
                tag_name=$(echo "$release_json" | jq -r '.tag_name')
            else
                tag_name=$(echo "$release_json" | grep -o '"tag_name"[^,]*' | cut -d'"' -f4)
            fi
            echo_info "Found release: $tag_name"

            if command -v jq &>/dev/null; then
                latest=$(echo "$release_json" | jq -r "[.assets[] | select(.name | contains(\"$arch\"))] | first | .url")
            elif command -v python3 &>/dev/null; then
                latest=$(echo "$release_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((a['url'] for a in d['assets'] if '$arch' in a['name']), ''))")
            else
                echo_error "jq or python3 required to parse GitHub API response"
                exit 1
            fi

            latest=$(echo "$latest" | tr -d '[:space:]')

            if [ -z "$latest" ] || [ "$latest" = "null" ]; then
                echo_error "Could not find release asset for $arch"
                exit 1
            fi

            _verbose "Downloading asset from: $latest"
            if ! curl --config <(printf 'header = "Authorization: token %s"\nheader = "Accept: application/octet-stream"' "$github_token") \
                "$latest" -L -o "$_tmp_download" >>"$log" 2>&1; then
                echo_error "Download failed, exiting"
                exit 1
            fi
        fi
    else
        # Free version - no auth needed
        _verbose "Free version - no authentication required"
        local release_json
        release_json=$(curl -sL "https://api.github.com/$release_endpoint") || {
            echo_error "Failed to query GitHub for release"
            exit 1
        }
        if [ "$is_array_response" = "true" ]; then
            if command -v jq &>/dev/null; then
                release_json=$(echo "$release_json" | jq '.[0]')
            elif command -v python3 &>/dev/null; then
                release_json=$(echo "$release_json" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)[0]))")
            else
                :
            fi
        fi

        local tag_name
        if command -v jq &>/dev/null; then
            tag_name=$(echo "$release_json" | jq -r '.tag_name')
        else
            tag_name=$(echo "$release_json" | grep -o '"tag_name"[^,]*' | head -1 | cut -d'"' -f4)
        fi
        echo_info "Found release: $tag_name"

        if command -v jq &>/dev/null; then
            latest=$(echo "$release_json" | jq -r ".assets[] | select(.name | contains(\"$arch\")) | .browser_download_url")
        else
            latest=$(echo "$release_json" | grep "browser_download_url" | grep "$arch" | head -1 | cut -d \" -f4)
        fi

        if [ -z "$latest" ]; then
            echo_error "Could not find release asset for $arch"
            exit 1
        fi

        _verbose "Downloading asset from: $latest"
        if ! curl "$latest" -L -o "$_tmp_download" >>"$log" 2>&1; then
            echo_error "Download failed, exiting"
            exit 1
        fi
    fi
    echo_progress_done "Archive downloaded"

    echo_progress_start "Extracting and replacing binary"
    _verbose "Extracting to $_tmp_extract"
    unzip -o "$_tmp_download" -d "$_tmp_extract" >>"$log" 2>&1 || {
        echo_error "Failed to extract"
        exit 1
    }
    mv "$_tmp_extract/$app_binary" "$app_dir/$app_binary"
    rm -rf "$_tmp_download" "$_tmp_extract"
    chmod +x "$app_dir/$app_binary"
    echo_progress_done "Binary replaced"

    # Restart services
    echo_progress_start "Restarting zurg services"
    _verbose "Restarting $app_servicefile"
    systemctl restart "$app_servicefile" 2>/dev/null || true
    if [ "$zurg_version" = "free" ] && [ -f "/etc/systemd/system/$app_mount_servicefile" ]; then
        sleep 2
        _verbose "Restarting $app_mount_servicefile"
        systemctl restart "$app_mount_servicefile" 2>/dev/null || true
    fi
    echo_progress_done "Services restarted"

    echo_success "Zurg binary updated ($zurg_version version)"
}

# Handle --remove flag
if [ "${1:-}" = "--remove" ]; then
    _remove_zurg "${2:-}"
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
            "Zurg" \
            "/$app_name" \
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

# Parse global flags from all arguments
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
        --latest) ZURG_USE_LATEST_TAG="true" ;;
        --upgrade) set -- "--update" "${@:2}" ;;
    esac
done

# Handle --switch-version flag
switch_mode="false"
if [ "${1:-}" = "--switch-version" ]; then
    if [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "Zurg is not installed. Run without --switch-version to install."
        exit 1
    fi

    current_version=$(swizdb get "zurg/version" 2>/dev/null) || true
    if [ -z "$current_version" ]; then
        current_version=$(_detect_zurg_version_from_config) || true
        if [ -n "$current_version" ]; then
            echo_info "Recovered version ($current_version) from config file, saving to swizdb"
            swizdb set "zurg/version" "$current_version"
        else
            echo_error "Cannot determine current zurg version. Reinstall to fix."
            exit 1
        fi
    fi

    # Determine target version
    if [ -n "${2:-}" ]; then
        if [[ "${2:-}" != "free" && "${2:-}" != "paid" ]]; then
            echo_error "Invalid version: ${2:-}. Use 'free' or 'paid'."
            exit 1
        fi
        target_version="$2"
    else
        # Prompt for target version
        if [ "$current_version" = "free" ]; then
            target_version="paid"
        else
            target_version="free"
        fi
        echo_info "Currently running: $current_version"
        if ! ask "Switch to $target_version version?" Y; then
            echo_info "Switch cancelled"
            exit 0
        fi
    fi

    # Check if already on target version
    if [ "$current_version" = "$target_version" ]; then
        echo_info "Already running $target_version version"
        exit 0
    fi

    switch_mode="true"
    _switch_version "$target_version" "$current_version"
fi

# Check if already installed (unless switching versions)
if [ "$switch_mode" != "true" ] && [ -f "/install/.$app_lockname.lock" ]; then
    current_version=$(swizdb get "zurg/version" 2>/dev/null) || true
    if [ -z "$current_version" ]; then
        current_version=$(_detect_zurg_version_from_config) || true
        if [ -n "$current_version" ]; then
            swizdb set "zurg/version" "$current_version"
        else
            current_version="unknown"
        fi
    fi
    echo_info "Zurg ($current_version) is already installed"

    # Normalize ZURG_USE_LATEST_TAG for comparison
    _use_latest="${ZURG_USE_LATEST_TAG:-}"
    _use_latest="${_use_latest,,}" # lowercase

    # Check if user wants to update/reinstall
    if [ "${1:-}" = "--update" ] || [ "${ZURG_UPGRADE:-}" = "true" ]; then
        # Parse --full flag for full reinstall
        full_reinstall=false
        for arg in "$@"; do
            case "$arg" in
                --full) full_reinstall=true ;;
            esac
        done

        if [ "$full_reinstall" = "false" ]; then
            # Default: binary-only update
            _upgrade_binary_zurg
            exit 0
        fi
        echo_info "Full reinstall requested..."
    elif [[ "$_use_latest" == "true" || "$_use_latest" == "1" || "$_use_latest" == "yes" ]] || [ -n "${ZURG_VERSION_TAG:-}" ]; then
        echo_info "Version change requested (tag mode), proceeding with install..."
    else
        echo_info "Use --update to update the binary, or --update --full to reinstall"
        echo_info "Use --switch-version to change between free/paid versions"
        echo_info "Use --latest or ZURG_VERSION_TAG=vX.X.X to install specific version"
        exit 0
    fi
fi

# Set owner for install
if [ -n "$ZURG_OWNER" ]; then
    echo_info "Setting ${app_name^} owner = $ZURG_OWNER"
    swizdb set "$app_name/owner" "$ZURG_OWNER"
fi

# Get mount point (interactive or from env)
_get_mount_point

_install_zurg
_systemd_zurg
_nginx_zurg

# Store configuration in swizdb for other scripts (decypharr)
swizdb set "zurg/mount_point" "$app_mount_point"
swizdb set "zurg/api_key" "$RD_TOKEN"
swizdb set "zurg/version" "$zurg_version"

# Update decypharr if installed
_update_decypharr_config "$app_mount_point" "$RD_TOKEN"

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Zurg" \
        "/$app_name" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
echo_info "Your Real-Debrid library is available at: $app_mount_point"

# Hint about symlink import script if Sonarr/Radarr are installed
if compgen -G "/install/.sonarr*.lock" >/dev/null 2>&1 || compgen -G "/install/.radarr*.lock" >/dev/null 2>&1; then
    echo ""
    echo_info "Sonarr/Radarr detected. To prevent 'Permission denied' errors"
    echo_info "when importing through symlinks to the zurg mount, consider using"
    echo_info "the symlink import script:"
    echo_info "  bash arr-symlink-import-setup.sh --install"
fi
