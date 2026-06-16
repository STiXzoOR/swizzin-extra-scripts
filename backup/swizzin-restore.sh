#!/bin/bash
#===============================================================================
# Swizzin Restore Script (BorgBackup)
# Config: /etc/swizzin-backup.conf (shared with swizzin-backup.sh)
#
# Usage:
#   swizzin-restore.sh                        Interactive restore
#   swizzin-restore.sh --list                 List archives
#   swizzin-restore.sh --app <name>           Restore app config
#   swizzin-restore.sh --mount [archive]      FUSE mount for browsing
#   swizzin-restore.sh --extract [archive] [path]  Extract specific path
#   swizzin-restore.sh --help                 Show help
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

CONF_FILE="/etc/swizzin-backup.conf"
[[ -f "$CONF_FILE" ]] || { echo "ERROR: Config not found: $CONF_FILE"; exit 1; }
# shellcheck source=/dev/null
. "$CONF_FILE"

[[ -z "${SWIZZIN_USER:-}" ]] && { echo "ERROR: SWIZZIN_USER not set in $CONF_FILE"; exit 1; }

export BORG_REPO
export BORG_PASSCOMMAND
export BORG_RSH
export BORG_REMOTE_PATH="${BORG_REMOTE_PATH:-borg-1.4}"

STOPPED_SERVICES_FILE="${STOPPED_SERVICES_FILE:-/var/run/swizzin-stopped-services.txt}"
MOUNT_POINT="/mnt/swizzin-restore"
SELECTED_ARCHIVE=""

#===============================================================================
# APP PATH MAPPINGS
# Maps app names to their config/data directories (relative paths for borg)
#===============================================================================

declare -A APP_PATHS=(
    # Arr stack
    ["sonarr"]="home/*/.config/Sonarr"
    ["radarr"]="home/*/.config/Radarr"
    ["lidarr"]="home/*/.config/Lidarr"
    ["prowlarr"]="home/*/.config/Prowlarr"
    ["bazarr"]="home/*/.config/bazarr"

    # Automation
    ["autobrr"]="home/*/.config/autobrr"
    ["autodl"]="home/*/.autodl"
    ["medusa"]="opt/medusa"
    ["mylar"]="home/*/.config/mylar"
    ["sickchill"]="opt/sickchill"
    ["sickgear"]="opt/sickgear"
    ["ombi"]="etc/Ombi"
    ["jackett"]="home/*/.config/Jackett"
    ["nzbhydra"]="home/*/.config/nzbhydra2"

    # Media servers
    ["emby"]="var/lib/emby"
    ["jellyfin"]="var/lib/jellyfin"
    ["plex"]="var/lib/plexmediaserver"
    ["tautulli"]="opt/tautulli"
    ["airsonic"]="var/lib/airsonic"
    ["calibreweb"]="home/*/.config/calibre-web"
    ["mango"]="opt/mango"
    ["navidrome"]="home/*/.config/navidrome"

    # Download clients
    ["deluge"]="home/*/.config/deluge"
    ["qbittorrent"]="home/*/.config/qBittorrent"
    ["rtorrent"]="home/*/.config/rtorrent"
    ["transmission"]="home/*/.config/transmission-daemon"
    ["nzbget"]="home/*/.config/nzbget"
    ["sabnzbd"]="home/*/.sabnzbd"
    ["flood"]="home/*/.config/flood"

    # Web/Utilities
    ["filebrowser"]="home/*/.config/Filebrowser"
    ["syncthing"]="home/*/.config/syncthing"
    ["pyload"]="home/*/.config/pyload"
    ["organizr"]="srv/organizr"
    ["nextcloud"]="var/www/nextcloud"
    ["netdata"]="etc/netdata"
    ["adguardhome"]="opt/AdGuardHome"

    # STiXzoOR custom apps
    ["overseerr"]="home/*/.config/overseerr"
    ["jellyseerr"]="home/*/.config/jellyseerr"
    ["seerr"]="home/*/.config/Seerr"
    ["decypharr"]="home/*/.config/Decypharr"
    ["notifiarr"]="home/*/.config/Notifiarr"
    ["huntarr"]="home/*/.config/Huntarr"
    ["cleanuparr"]="opt/cleanuparr"
    ["byparr"]="home/*/.config/Byparr"
    ["flaresolverr"]="home/*/.config/FlareSolverr"
    ["subgen"]="home/*/.config/Subgen"
    ["lingarr"]="opt/lingarr/config"
    ["mdblistarr"]="opt/mdblistarr/db"
    ["zurg"]="home/*/.config/zurg"
    ["mdblist-sync"]="opt/swizzin-extras"

    # Media Server Notifier
    ["autopulse"]="opt/autopulse"

    # Debrid Indexer Stack
    ["stremthru"]="opt/stremthru/data"
    ["aiostreams"]="opt/aiostreams"
    ["mediafusion"]="opt/mediafusion"
    ["zilean"]="opt/zilean"
    ["nzbdav"]="opt/nzbdav/config"
    ["newtarr"]="opt/newtarr"
    ["litterbox"]="opt/litterbox"
    ["nzbhydra2"]="opt/nzbhydra2/config"
    ["easynews-indexer"]="opt/easynews-indexer"
    ["babysitarr"]="opt/babysitarr"

    # Media Management
    ["checkrr"]="opt/checkrr"
    ["posterizarr"]="opt/posterizarr"

    # Stalled download manager
    ["swaparr"]="opt/swaparr"

    # Analytics
    ["tracearr"]="opt/tracearr"

    # Additional
    ["wireguard"]="etc/wireguard"
    ["tailscale"]="var/lib/tailscale"
    ["rutorrent"]="srv/rutorrent"

    # System
    ["nginx"]="etc/nginx"
    ["letsencrypt"]="etc/letsencrypt"
    ["swizzin"]="etc/swizzin"
    ["symlinks"]="mnt/symlinks"
    ["panel"]="opt/swizzin/core/custom"
    ["swizzin-extras"]="opt/swizzin-extras"
    ["cron"]="var/spool/cron"
)

#===============================================================================
# SERVICE DEFINITIONS (subset for restore — same as backup script)
#===============================================================================

declare -A SERVICE_TYPES=(
    ["autobrr"]="user" ["autodl"]="user" ["bazarr"]="user" ["lidarr"]="user"
    ["medusa"]="user" ["mylar"]="user" ["ombi"]="system" ["sickchill"]="user"
    ["sickgear"]="user" ["sonarr"]="user" ["radarr"]="user" ["prowlarr"]="user"
    ["airsonic"]="system" ["calibreweb"]="user" ["emby"]="system"
    ["jellyfin"]="system" ["mango"]="user" ["navidrome"]="user"
    ["plex"]="system" ["tautulli"]="user"
    ["deluge"]="user" ["deluged"]="user" ["deluge-web"]="user"
    ["flood"]="user" ["qbittorrent"]="user" ["rtorrent"]="user"
    ["transmission"]="user" ["nzbget"]="user" ["sabnzbd"]="user"
    ["nzbhydra"]="user" ["jackett"]="user"
    ["filebrowser"]="user" ["syncthing"]="user" ["pyload"]="user"
    ["overseerr"]="system" ["jellyseerr"]="system" ["seerr"]="system"
    ["decypharr"]="system" ["notifiarr"]="system" ["huntarr"]="system"
    ["cleanuparr"]="system" ["swaparr"]="system" ["byparr"]="system" ["flaresolverr"]="system"
    ["subgen"]="system" ["lingarr"]="system" ["libretranslate"]="system"
    ["mdblistarr"]="system"
    ["mdblist-filter-proxy"]="system"
    ["autopulse"]="system"
    ["stremthru"]="system" ["aiostreams"]="system" ["mediafusion"]="system" ["zilean"]="system"
    ["nzbdav"]="system" ["newtarr"]="system" ["litterbox"]="system"
    ["nzbhydra2"]="system"
    ["easynews-indexer"]="system"
    ["babysitarr"]="system"
    ["zurg"]="system" ["rclone-zurg"]="system"
    ["netdata"]="system" ["organizr"]="system" ["nextcloud"]="system"
    ["adguardhome"]="system"
    ["tailscale"]="system"
)

declare -A SERVICE_NAME_MAP=(
    ["emby"]="emby-server"
    ["plex"]="plexmediaserver"
    ["tailscale"]="tailscaled"
)

#===============================================================================
# FUNCTIONS
#===============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

get_service_name() {
    local app="$1"
    local type="${SERVICE_TYPES[$app]:-}"
    local mapped_name="${SERVICE_NAME_MAP[$app]:-$app}"

    case "$type" in
        user)   echo "${app}@${SWIZZIN_USER}" ;;
        system) echo "$mapped_name" ;;
        *)      echo "$app" ;;
    esac
}

is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

stop_app_service() {
    local app="$1"
    [[ -z "${SERVICE_TYPES[$app]:-}" ]] && return

    local service
    service=$(get_service_name "$app")
    if is_service_active "$service"; then
        log "Stopping: $service"
        systemctl stop "$service" 2>/dev/null
        echo "$service" >> "$STOPPED_SERVICES_FILE"
    fi

    # Multi-instance (lock files use underscores, service names use hyphens)
    if [[ "$app" == "sonarr" || "$app" == "radarr" || "$app" == "bazarr" ]]; then
        for lockfile in /install/."${app}"_*.lock; do
            [[ -f "$lockfile" ]] || continue
            local lock_name
            lock_name=$(basename "$lockfile" .lock | sed 's/^\.//')
            # Convert underscore to hyphen for service name
            local svc="${lock_name/_/-}"
            if is_service_active "$svc"; then
                log "Stopping: $svc (multi-instance)"
                systemctl stop "$svc" 2>/dev/null
                echo "$svc" >> "$STOPPED_SERVICES_FILE"
            fi
        done
    fi
}

start_stopped_services() {
    [[ ! -f "$STOPPED_SERVICES_FILE" ]] && return

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        log "Starting: $service"
        systemctl start "$service" 2>/dev/null || log "WARNING: Failed to start $service"
    done < "$STOPPED_SERVICES_FILE"

    rm -f "$STOPPED_SERVICES_FILE"
}

cleanup() {
    if [[ -f "$STOPPED_SERVICES_FILE" ]]; then
        log "TRAP: Restarting services after unexpected exit..."
        start_stopped_services
    fi
    # Unmount if still mounted
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        borg umount "$MOUNT_POINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT ERR INT TERM

select_archive() {
    local archives
    archives=$(borg list --short 2>/dev/null)
    [[ -z "$archives" ]] && { log "ERROR: No archives found"; exit 1; }

    echo ""
    echo "Available archives:"
    echo "==================="
    local i=1
    local archive_array=()
    while IFS= read -r archive; do
        printf "  %3d) %s\n" "$i" "$archive"
        archive_array+=("$archive")
        ((i++))
    done <<< "$archives"

    echo ""
    read -rp "Select archive number [1]: " choice
    choice="${choice:-1}"

    if [[ "$choice" -lt 1 || "$choice" -gt ${#archive_array[@]} ]]; then
        log "ERROR: Invalid selection"
        exit 1
    fi

    SELECTED_ARCHIVE="${archive_array[$((choice-1))]}"
    echo "Selected: $SELECTED_ARCHIVE"
}

#===============================================================================
# COMMANDS
#===============================================================================

cmd_list() {
    borg list
}

cmd_mount() {
    local archive="${1:-}"

    if [[ -z "$archive" ]]; then
        select_archive
        archive="$SELECTED_ARCHIVE"
    fi

    mkdir -p "$MOUNT_POINT"

    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log "Already mounted at $MOUNT_POINT — unmounting first"
        borg umount "$MOUNT_POINT"
    fi

    log "Mounting archive: $archive"
    log "Mount point: $MOUNT_POINT"
    borg mount "::${archive}" "$MOUNT_POINT"

    echo ""
    echo "Archive mounted at: $MOUNT_POINT"
    echo "Browse with: ls $MOUNT_POINT"
    echo "Unmount with: borg umount $MOUNT_POINT"
    echo ""
    echo "Press Enter to unmount, or Ctrl+C to leave mounted..."
    read -r
    borg umount "$MOUNT_POINT"
    log "Unmounted"
}

cmd_extract() {
    local archive="${1:-}"
    local extract_path="${2:-}"

    if [[ -z "$archive" ]]; then
        select_archive
        archive="$SELECTED_ARCHIVE"
    fi

    if [[ -z "$extract_path" ]]; then
        read -rp "Path to extract (relative, e.g. home/<user>/.config/Sonarr): " extract_path
    fi

    local staging="/tmp/borg-restore-$(date +%s)"
    mkdir -p "$staging"

    log "Extracting from archive: $archive"
    log "Path: $extract_path"
    log "Destination: $staging"

    cd "$staging"
    borg extract "::${archive}" "$extract_path"
    cd - >/dev/null

    echo ""
    echo "Extracted to: $staging"
    echo "Inspect with: ls -la $staging/$extract_path"
    echo ""
    echo "To apply: cp -a $staging/$extract_path /actual/target/"
}

cmd_app_restore() {
    local app="$1"

    # Handle multi-instance (sonarr-4k -> base path sonarr with instance suffix)
    local base_app="$app"
    local instance_suffix=""
    if [[ "$app" =~ ^(sonarr|radarr|bazarr)-(.+)$ ]]; then
        base_app="${BASH_REMATCH[1]}"
        instance_suffix="${BASH_REMATCH[2]}"
    fi

    # Get path for base app or direct app
    local app_path=""
    if [[ -n "$instance_suffix" ]]; then
        # Multi-instance: e.g., home/*/.config/sonarr-4k
        app_path="home/*/.config/${app}"
    else
        app_path="${APP_PATHS[$app]:-}"
    fi

    # Resolve glob wildcards to actual user path for borg extract
    app_path="${app_path//\*/$SWIZZIN_USER}"

    if [[ -z "$app_path" ]]; then
        echo "ERROR: Unknown app '$app'"
        echo ""
        echo "Known apps:"
        printf '  %s\n' "${!APP_PATHS[@]}" | sort
        exit 1
    fi

    select_archive
    local archive="$SELECTED_ARCHIVE"

    echo ""
    echo "Restore details:"
    echo "  App:     $app"
    echo "  Archive: $archive"
    echo "  Path:    $app_path"
    echo ""

    read -rp "This will overwrite existing files. Continue? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 0; }

    # Stop the app service if it's running
    stop_app_service "${base_app}"

    log "Restoring $app from archive: $archive"

    cd /
    borg extract "::${archive}" "$app_path" 2>&1
    cd - >/dev/null

    log "Restore complete for $app"

    # Restart services
    start_stopped_services

    echo ""
    echo "Restore complete. Verify $app is working correctly."
}

cmd_interactive() {
    echo "==============================="
    echo "  Swizzin Backup Restore"
    echo "==============================="
    echo ""
    echo "Modes:"
    echo "  1) Restore app config"
    echo "  2) Browse archive (FUSE mount)"
    echo "  3) Extract specific path"
    echo "  4) List archives"
    echo "  5) Full restore (destructive)"
    echo ""
    read -rp "Select mode [1-5]: " mode

    case "$mode" in
        1)
            echo ""
            echo "Available apps:"
            printf '  %s\n' "${!APP_PATHS[@]}" | sort | column
            echo ""
            read -rp "App name: " app_name
            cmd_app_restore "$app_name"
            ;;
        2)
            cmd_mount ""
            ;;
        3)
            cmd_extract "" ""
            ;;
        4)
            cmd_list
            ;;
        5)
            echo ""
            echo "WARNING: Full restore will overwrite ALL files on this system!"
            echo "This should only be used on a fresh OS installation."
            echo ""
            read -rp "Type 'RESTORE' to confirm: " confirm
            [[ "$confirm" == "RESTORE" ]] || { echo "Aborted"; exit 0; }

            select_archive
            local archive="$SELECTED_ARCHIVE"

            log "FULL RESTORE from archive: $archive"
            cd /
            borg extract "::${archive}"
            cd - >/dev/null

            # Rebuild symlinks if present
            if [[ -d /mnt/symlinks ]]; then
                log "Symlinks directory restored at /mnt/symlinks"
            fi

            log "Full restore complete. Reboot recommended."
            ;;
        *)
            echo "Invalid selection"
            exit 1
            ;;
    esac
}

#===============================================================================
# MAIN
#===============================================================================

[[ $EUID -ne 0 ]] && { echo "Must run as root"; exit 1; }

case "${1:-}" in
    --list)
        cmd_list
        ;;
    --app)
        [[ -z "${2:-}" ]] && { echo "Usage: $(basename "$0") --app <name>"; exit 1; }
        cmd_app_restore "$2"
        ;;
    --mount)
        cmd_mount "${2:-}"
        ;;
    --extract)
        cmd_extract "${2:-}" "${3:-}"
        ;;
    --help|-h)
        echo "Usage: $(basename "$0") [OPTION]"
        echo ""
        echo "Options:"
        echo "  (none)                       Interactive restore"
        echo "  --list                       List archives"
        echo "  --app <name>                 Restore app config (e.g., sonarr, radarr-4k)"
        echo "  --mount [archive]            FUSE mount for browsing"
        echo "  --extract [archive] [path]   Extract specific path to staging dir"
        echo "  --help                       Show this help"
        echo ""
        echo "Known apps:"
        printf '  %s\n' "${!APP_PATHS[@]}" | sort | column
        ;;
    "")
        cmd_interactive
        ;;
    *)
        echo "Unknown option: $1"
        echo "Run '$(basename "$0") --help' for usage"
        exit 1
        ;;
esac
