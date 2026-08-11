#!/bin/bash
#===============================================================================
# Swizzin Backup Script (BorgBackup)
# Supports: All official Swizzin apps + STiXzoOR/swizzin-scripts custom apps
#
# Target: Remote borg repository (any SSH-accessible borg server)
# Config: /etc/swizzin-backup.conf
#
# Usage:
#   swizzin-backup.sh              Run full backup (default)
#   swizzin-backup.sh --dry-run    Show what would be backed up
#   swizzin-backup.sh --list       List archives
#   swizzin-backup.sh --info       Show repo info
#   swizzin-backup.sh --check      Run borg check
#   swizzin-backup.sh --verify     Run borg check --verify-data (full integrity)
#   swizzin-backup.sh --services   List discovered services (no backup)
#
# Official Swizzin apps supported:
#   Automation: autobrr, autodl, bazarr, lidarr, medusa, mylar, ombi,
#               sickchill, sickgear, sonarr, radarr, prowlarr
#   Media: airsonic, calibreweb, emby, jellyfin, mango, navidrome, plex, tautulli
#   Torrents: deluge, flood, qbittorrent, rtorrent, rutorrent, transmission
#   Usenet: nzbget, sabnzbd, nzbhydra
#   Indexers: jackett
#   Web: nginx, organizr, panel, filebrowser
#   Utilities: netdata, pyload, wireguard, syncthing, nextcloud, rclone
#
# STiXzoOR custom apps:
#   Multi-instance sonarr/radarr, zurg, decypharr, notifiarr, byparr,
#   flaresolverr, huntarr, subgen, lingarr, cleanuparr, seerr, overseerr, jellyseerr,
#   mdblist-sync, mdblist-filter-proxy, mdblistarr, stremthru, mediafusion,
#   zilean, nzbdav, newtarr, swaparr, litterbox, nzbhydra2, aiostreams,
#   easynews-indexer, babysitarr, tailscale, remux
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

CONF_FILE="/etc/swizzin-backup.conf"
[[ -f "$CONF_FILE" ]] || {
    echo "ERROR: Config not found: $CONF_FILE"
    exit 1
}
# shellcheck source=/dev/null
. "$CONF_FILE"

[[ -z "${SWIZZIN_USER:-}" ]] && {
    echo "ERROR: SWIZZIN_USER not set in $CONF_FILE"
    exit 1
}

# Export borg environment variables
export BORG_REPO
export BORG_PASSCOMMAND
export BORG_RSH
export BORG_REMOTE_PATH="${BORG_REMOTE_PATH:-borg-1.4}"

# Paths with defaults
LOCKFILE="${LOCKFILE:-/var/run/swizzin-backup.lock}"
LOGFILE="${LOGFILE:-/var/log/swizzin-backup.log}"
EXCLUDES_FILE="${EXCLUDES_FILE:-/etc/swizzin-excludes.txt}"
STOPPED_SERVICES_FILE="${STOPPED_SERVICES_FILE:-/var/run/swizzin-stopped-services.txt}"
PAUSED_JOBS_FILE="${PAUSED_JOBS_FILE:-/var/run/swizzin-paused-jobs.txt}"

# Service management
STOP_MODE="${STOP_MODE:-critical}"

# Progress heartbeat interval (seconds, 0 to disable)
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-60}"

# Max file size in /mnt/symlinks to include in backup (MB, 0 = no limit)
SYMLINKS_SIZE_LIMIT="${SYMLINKS_SIZE_LIMIT:-100}"

# Retention with defaults
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
KEEP_YEARLY="${KEEP_YEARLY:-2}"

# Notification config defaults
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
PUSHOVER_USER="${PUSHOVER_USER:-}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"
NOTIFIARR_API_KEY="${NOTIFIARR_API_KEY:-}"
EMAIL_TO="${EMAIL_TO:-}"
HC_UUID="${HC_UUID:-}"

#===============================================================================
# SERVICE DEFINITIONS
# Types: user = <app>@<user>.service, system = <app>.service
#===============================================================================

declare -A SERVICE_TYPES=(
    #=== OFFICIAL SWIZZIN APPS ===

    # Automation
    ["autobrr"]="user"
    ["autodl"]="user"
    ["bazarr"]="user"
    ["lidarr"]="user"
    ["medusa"]="user"
    ["mylar"]="user"
    ["ombi"]="system" # ombi.service (from apt)
    ["sickchill"]="user"
    ["sickgear"]="user"
    ["sonarr"]="user"
    ["radarr"]="user"
    ["prowlarr"]="user"

    # Media Servers
    ["airsonic"]="system"
    ["calibreweb"]="user"
    ["emby"]="system"     # emby-server.service
    ["jellyfin"]="system" # jellyfin.service
    ["mango"]="user"
    ["navidrome"]="user"
    ["plex"]="system" # plexmediaserver.service
    ["tautulli"]="user"

    # Torrent Clients
    ["deluge"]="user"
    ["deluged"]="user"
    ["deluge-web"]="user"
    ["flood"]="user"
    ["qbittorrent"]="user"
    ["rtorrent"]="user"
    ["transmission"]="user"

    # Usenet
    ["nzbget"]="user"
    ["sabnzbd"]="user"
    ["nzbhydra"]="user"

    # Indexers
    ["jackett"]="user"

    # Web/Utilities
    ["filebrowser"]="user"
    ["netdata"]="system"
    ["pyload"]="user"
    ["syncthing"]="user"
    ["nextcloud"]="system" # php-fpm based
    ["organizr"]="system"  # php-fpm based

    #=== STiXzoOR CUSTOM APPS ===
    # All custom apps use plain .service files (not @user templates)

    # Request Management (NOT in official Swizzin)
    ["overseerr"]="system"
    ["jellyseerr"]="system"
    ["seerr"]="system"

    # Arr Helpers
    ["decypharr"]="system"
    ["notifiarr"]="system"
    ["huntarr"]="system"
    ["cleanuparr"]="system"
    ["swaparr"]="system"

    # Cloudflare Bypass
    ["byparr"]="system"
    ["flaresolverr"]="system"

    # Subtitles / Translation
    ["subgen"]="system"
    ["lingarr"]="system"
    ["libretranslate"]="system"

    # MDBList Integration
    ["mdblistarr"]="system"
    ["mdblist-filter-proxy"]="system"

    # Real-Debrid
    ["zurg"]="system"
    ["rclone-zurg"]="system"

    # Media Server Notifier
    ["autopulse"]="system"

    # Debrid Indexer Stack
    ["stremthru"]="system"
    ["aiostreams"]="system"
    ["mediafusion"]="system"
    ["zilean"]="system"
    ["nzbdav"]="system"
    ["rclone-nzbdav"]="system"
    ["newtarr"]="system"
    ["litterbox"]="system"
    ["nzbhydra2"]="system"
    ["easynews-indexer"]="system"

    # Jellyfin-compatible media server (Docker)
    ["remux"]="system"

    # Arr Monitoring / Self-healing
    ["babysitarr"]="system"

    # Media Management
    ["checkrr"]="system"
    ["posterizarr"]="system"

    # Analytics
    ["tracearr"]="system"

    # DNS
    ["adguardhome"]="system"

    # VPN / Tunnels
    ["tailscale"]="system"
)

# Service name mappings (when systemd name differs from app name)
declare -A SERVICE_NAME_MAP=(
    ["emby"]="emby-server"
    ["plex"]="plexmediaserver"
    ["tailscale"]="tailscaled"
)

# Ordered service stop list — downstream consumers first, infrastructure last
# Services are stopped in this order and started in reverse
SERVICE_STOP_ORDER=(
    # Downstream first (API consumers)
    babysitarr swaparr huntarr cleanuparr notifiarr tautulli
    overseerr jellyseerr seerr ombi
    # Automation
    bazarr autobrr autodl
    sonarr radarr lidarr prowlarr
    medusa mylar sickchill sickgear
    # Indexers/bypass
    jackett nzbhydra nzbhydra2 easynews-indexer byparr flaresolverr stremthru aiostreams mediafusion zilean rclone-nzbdav nzbdav
    # Media servers
    emby jellyfin plex remux airsonic calibreweb mango navidrome
    # Download clients
    flood deluge deluged deluge-web qbittorrent rtorrent transmission
    nzbget sabnzbd
    # Utilities
    filebrowser syncthing pyload netdata adguardhome subgen lingarr libretranslate mdblistarr mdblist-filter-proxy newtarr litterbox autopulse checkrr posterizarr tracearr
    # Real-Debrid (stop last, start first)
    zurg decypharr
    # Never stop: rclone-zurg, organizr, nextcloud, nginx, panel
)

# Services that MUST stop for consistent backup (SQLite databases)
# Used when STOP_MODE=critical — only these are stopped
declare -A SERVICE_STOP_CRITICAL=(
    ["sonarr"]=1 ["radarr"]=1 ["lidarr"]=1 ["prowlarr"]=1 ["bazarr"]=1
    ["autobrr"]=1 ["medusa"]=1 ["mylar"]=1 ["sickchill"]=1 ["sickgear"]=1
    ["jackett"]=1 ["nzbhydra"]=1
    ["overseerr"]=1 ["jellyseerr"]=1 ["seerr"]=1 ["ombi"]=1
    ["tautulli"]=1
    ["emby"]=1 ["jellyfin"]=1
    ["huntarr"]=1
    ["mdblistarr"]=1
    ["mdblist-filter-proxy"]=1
    ["stremthru"]=1 ["aiostreams"]=1 ["autopulse"]=1
    ["mediafusion"]=1 ["zilean"]=1
    ["nzbdav"]=1
    ["rclone-nzbdav"]=1
    ["remux"]=1
    ["decypharr"]=1
    ["tracearr"]=1
    ["babysitarr"]=1
)

#===============================================================================
# FUNCTIONS
#===============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

_format_duration() {
    local secs=$1
    if [[ $secs -ge 60 ]]; then
        echo "$((secs / 60))m $((secs % 60))s"
    else
        echo "${secs}s"
    fi
}

_progress_heartbeat() {
    local start=$1
    local interval=$2
    while true; do
        sleep "$interval"
        local elapsed=$(($(date +%s) - start))
        log "  ... backup in progress ($((elapsed / 60))m elapsed)"
    done
}

healthcheck() {
    local status="$1"
    [[ -n "${HC_UUID:-}" ]] && curl -fsS -m 10 --retry 3 "https://hc-ping.com/${HC_UUID}${status}" &>/dev/null || true
}

_capture_system_state() {
    # Snapshot bare-metal-restore data to /etc/swizzin-backup-state/ so it lands
    # in the borg archive (since /etc is included). Reading these on restore tells
    # us which packages to apt-install, how to recreate partitions/RAID/swap, and
    # what services were enabled. All commands are best-effort — a missing tool
    # must not fail the backup.
    local state_dir="/etc/swizzin-backup-state"
    mkdir -p "$state_dir" || return 0
    log "Capturing system state to $state_dir"

    {
        echo "# Captured at $(date -Iseconds) on $(hostname)"
        echo "# Restore: cat dpkg-selections.txt | xargs apt-get install -y"
    } >"$state_dir/README.txt"

    dpkg --get-selections >"$state_dir/dpkg-selections.txt" 2>/dev/null || true
    apt-mark showmanual >"$state_dir/apt-manual.txt" 2>/dev/null || true
    dpkg --print-architecture >"$state_dir/dpkg-arch.txt" 2>/dev/null || true

    lsblk -f -o NAME,FSTYPE,FSVER,LABEL,UUID,FSAVAIL,FSUSE%,MOUNTPOINT >"$state_dir/lsblk.txt" 2>/dev/null || true
    blkid >"$state_dir/blkid.txt" 2>/dev/null || true
    cat /proc/mdstat >"$state_dir/mdstat.txt" 2>/dev/null || true
    mdadm --detail --scan >"$state_dir/mdadm-scan.txt" 2>/dev/null || true
    for md in /dev/md[0-9]*; do
        [[ -b "$md" ]] && mdadm --detail "$md" 2>/dev/null
    done >"$state_dir/mdadm-detail.txt" || true

    # Partition tables — sfdisk -d is replayable via `sfdisk /dev/X < table.txt`
    : >"$state_dir/partition-tables.txt"
    for disk in /dev/nvme[0-9]n[0-9] /dev/sd[a-z]; do
        if [[ -b "$disk" ]]; then
            echo "### $disk ###" >>"$state_dir/partition-tables.txt"
            sfdisk -d "$disk" 2>/dev/null >>"$state_dir/partition-tables.txt" || true
        fi
    done

    # NVMe health snapshot (baseline for future comparison after replacement)
    if command -v nvme >/dev/null 2>&1; then
        : >"$state_dir/nvme-smart.txt"
        for nvd in /dev/nvme[0-9]; do
            if [[ -c "$nvd" ]]; then
                echo "### $nvd ###" >>"$state_dir/nvme-smart.txt"
                nvme smart-log "$nvd" 2>/dev/null >>"$state_dir/nvme-smart.txt" || true
                nvme id-ctrl "$nvd" 2>/dev/null | grep -E "^mn |^sn |^fr " >>"$state_dir/nvme-smart.txt" || true
            fi
        done
    fi

    # Network state — netplan files are in /etc already, this is the runtime view
    ip -br addr >"$state_dir/ip-addr.txt" 2>/dev/null || true
    ip -br route >"$state_dir/ip-route.txt" 2>/dev/null || true

    systemctl list-unit-files --state=enabled --no-pager --no-legend >"$state_dir/systemctl-enabled.txt" 2>/dev/null || true
    systemctl list-unit-files --state=masked --no-pager --no-legend >"$state_dir/systemctl-masked.txt" 2>/dev/null || true

    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' >"$state_dir/docker-ps.txt" 2>/dev/null || true
        docker network ls >"$state_dir/docker-networks.txt" 2>/dev/null || true
    fi

    crontab -l >"$state_dir/crontab-root.txt" 2>/dev/null || true
    if [[ -n "${SWIZZIN_USER:-}" ]]; then
        crontab -u "$SWIZZIN_USER" -l >"$state_dir/crontab-${SWIZZIN_USER}.txt" 2>/dev/null || true
    fi

    cp /etc/os-release "$state_dir/os-release.txt" 2>/dev/null || true
    uname -a >"$state_dir/uname.txt" 2>/dev/null || true
    hostname >"$state_dir/hostname.txt" 2>/dev/null || true

    # Swizzin installed apps — what was on this host
    ls /install/.*.lock 2>/dev/null | sed 's|.*/\.||;s|\.lock$||' | sort >"$state_dir/swizzin-installed-apps.txt" || true

    return 0
}

_generate_size_excludes() {
    local limit_mb="$1"
    local out_file="$2"

    : >"$out_file"
    [[ "$limit_mb" -eq 0 ]] && return 0
    [[ ! -d /mnt/symlinks ]] && return 0

    local count=0
    while IFS= read -r filepath; do
        # Write both with and without leading / to match regardless of
        # how borg normalizes the path for explicit source directories
        echo "pf:${filepath}" >>"$out_file"
        echo "pf:${filepath#/}" >>"$out_file"
        ((count++)) || true
    done < <(find /mnt/symlinks -type f -size +"${limit_mb}M" 2>/dev/null || true)

    if [[ "$count" -gt 0 ]]; then
        log "Excluding $count files from /mnt/symlinks exceeding ${limit_mb}MB"
    fi
    return 0
}

#===============================================================================
# NOTIFICATIONS (shared library)
#===============================================================================

# Override log warn before sourcing shared notifications
_notify_log_warn() { log "WARNING: $1"; }

# shellcheck source=../lib/notifications.sh
_notifications_lib="/usr/local/lib/swizzin/notifications.sh"
[[ -f "$_notifications_lib" ]] || _notifications_lib="$(dirname "${BASH_SOURCE[0]}")/../lib/notifications.sh"
. "$_notifications_lib"
unset _notifications_lib

#===============================================================================
# SERVICE MANAGEMENT
#===============================================================================

get_service_name() {
    local app="$1"
    local type="${SERVICE_TYPES[$app]:-}"
    local mapped_name="${SERVICE_NAME_MAP[$app]:-$app}"

    case "$type" in
        user)
            # Check if template unit exists; fall back to plain service
            if [[ -f "/etc/systemd/system/${app}@.service" ]] \
                || [[ -f "/lib/systemd/system/${app}@.service" ]]; then
                echo "${app}@${SWIZZIN_USER}"
            else
                echo "$mapped_name"
            fi
            ;;
        system) echo "$mapped_name" ;;
        *) echo "$app" ;;
    esac
}

discover_multi_instance_services() {
    local instances=()

    # Discover sonarr-*, radarr-*, bazarr-* multi-instance services
    # These are regular .service files (NOT @user templates)
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && instances+=("$svc")
    done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null \
        | grep -oE "(sonarr|radarr|bazarr)-[a-z0-9]+\.service" \
        | sed 's/\.service$//')

    # Also check lock files (underscore separator, convert to hyphen for service name)
    for lockfile in /install/.sonarr_*.lock /install/.radarr_*.lock /install/.bazarr_*.lock; do
        if [[ -f "$lockfile" ]]; then
            local lock_name
            lock_name=$(basename "$lockfile" .lock | sed 's/^\.//')
            # Convert underscore to hyphen: sonarr_4k -> sonarr-4k
            local svc="${lock_name/_/-}"
            # shellcheck disable=SC2076
            if [[ ! " ${instances[*]:-} " =~ " ${svc} " ]]; then
                instances+=("$svc")
            fi
        fi
    done

    [[ ${#instances[@]} -gt 0 ]] && printf '%s\n' "${instances[@]}"
}

is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Kill any orphaned processes for arr apps that survive systemctl stop.
# Radarr/Sonarr/etc self-restart via child processes that can escape the
# service cgroup (especially with KillMode=process). This ensures no
# stray processes hold SQLite database locks during backup.
kill_stray_arr_processes() {
    local app="$1"
    local binary data_dir

    case "$app" in
        sonarr*)  binary="Sonarr"  ;;
        radarr*)  binary="Radarr"  ;;
        lidarr*)  binary="Lidarr"  ;;
        prowlarr) binary="Prowlarr" ;;
        bazarr*)  binary="bazarr"  ;;
        *)        return 0 ;;
    esac

    # Determine data directory for this instance
    case "$app" in
        sonarr)    data_dir="/home/${SWIZZIN_USER}/.config/Sonarr" ;;
        radarr)    data_dir="/home/${SWIZZIN_USER}/.config/Radarr" ;;
        lidarr)    data_dir="/home/${SWIZZIN_USER}/.config/Lidarr" ;;
        prowlarr)  data_dir="/home/${SWIZZIN_USER}/.config/Prowlarr" ;;
        bazarr)    data_dir="/home/${SWIZZIN_USER}/.config/bazarr" ;;
        *)         data_dir="/home/${SWIZZIN_USER}/.config/${app}" ;;
    esac

    local stale_pids
    stale_pids=$(pgrep -f "${binary}.*${data_dir}" 2>/dev/null || true)
    if [[ -n "$stale_pids" ]]; then
        log "  Killing stray ${app} processes: ${stale_pids//$'\n'/ }"
        echo "$stale_pids" | xargs kill 2>/dev/null || true
        sleep 2
        # SIGKILL any survivors
        stale_pids=$(pgrep -f "${binary}.*${data_dir}" 2>/dev/null || true)
        if [[ -n "$stale_pids" ]]; then
            log "  Force-killing stubborn ${app} processes: ${stale_pids//$'\n'/ }"
            echo "$stale_pids" | xargs kill -9 2>/dev/null || true
            sleep 1
        fi
    fi
}

pause_scheduled_jobs() {
    log "=========================================="
    log "Pausing scheduled jobs..."
    log "=========================================="

    local paused=()

    # --- Systemd timers ---
    local timers=(
        arr-force-import.timer
        arr-maintenance.timer
        mdblist-sync.timer
        mdblist-sync-cleanup.timer
        swizzin-backup-verify.timer
    )
    for timer in "${timers[@]}"; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            systemctl stop "$timer" 2>/dev/null && {
                log "  Paused timer: $timer"
                paused+=("timer:$timer")
            }
        fi
    done

    # --- Cron files in /etc/cron.d ---
    local cron_dir="/etc/cron.d"
    local cron_pause_dir="/etc/cron.d/.backup-paused"
    local cron_files=(
        decypharr-watchdog
        media-repair-links
    )
    if [[ ${#cron_files[@]} -gt 0 ]]; then
        mkdir -p "$cron_pause_dir"
        for cronfile in "${cron_files[@]}"; do
            if [[ -f "$cron_dir/$cronfile" ]]; then
                mv "$cron_dir/$cronfile" "$cron_pause_dir/$cronfile" && {
                    log "  Paused cron: $cronfile"
                    paused+=("cron:$cronfile")
                }
            fi
        done
    fi

    # --- Root crontab ---
    local root_crontab
    root_crontab=$(crontab -l 2>/dev/null) || true
    if [[ -n "$root_crontab" ]]; then
        echo "$root_crontab" > "$cron_pause_dir/root-crontab.bak"
        crontab -r 2>/dev/null && {
            log "  Paused root crontab ($(echo "$root_crontab" | grep -c '^[^#]') entries)"
            paused+=("crontab:root")
        }
    fi

    # --- Docker containers that run scheduled tasks ---
    local containers=(
        swaparr-sonarr
        swaparr-sonarr-4k
        swaparr-sonarr-anime
        swaparr-radarr
        swaparr-radarr-4k
    )
    for container in "${containers[@]}"; do
        if docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
            docker pause "$container" 2>/dev/null && {
                log "  Paused container: $container"
                paused+=("container:$container")
            }
        fi
    done

    log "Paused ${#paused[@]} scheduled jobs"
    printf '%s\n' "${paused[@]}" > "$PAUSED_JOBS_FILE"
}

resume_scheduled_jobs() {
    log "=========================================="
    log "Resuming scheduled jobs..."
    log "=========================================="

    [[ ! -f "$PAUSED_JOBS_FILE" ]] && {
        log "  No paused jobs to resume"
        return
    }

    local failed=()
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local type="${entry%%:*}"
        local name="${entry#*:}"
        case "$type" in
            timer)
                systemctl start "$name" 2>/dev/null && log "  Resumed timer: $name" \
                    || failed+=("$entry")
                ;;
            cron)
                local src="/etc/cron.d/.backup-paused/$name"
                if [[ -f "$src" ]]; then
                    mv "$src" "/etc/cron.d/$name" && log "  Resumed cron: $name" \
                        || failed+=("$entry")
                fi
                ;;
            crontab)
                local bak="/etc/cron.d/.backup-paused/root-crontab.bak"
                if [[ -f "$bak" ]]; then
                    crontab "$bak" && log "  Resumed root crontab" \
                        || failed+=("$entry")
                    rm -f "$bak"
                fi
                ;;
            container)
                docker unpause "$name" 2>/dev/null && log "  Resumed container: $name" \
                    || failed+=("$entry")
                ;;
        esac
    done < "$PAUSED_JOBS_FILE"

    rm -f "$PAUSED_JOBS_FILE"
    rmdir "/etc/cron.d/.backup-paused" 2>/dev/null || true

    if [[ ${#failed[@]} -gt 0 ]]; then
        log "WARNING: Failed to resume: ${failed[*]}"
    fi
}

stop_services() {
    if [[ "$STOP_MODE" == "none" ]]; then
        log "STOP_MODE=none — skipping service stops"
        return
    fi

    log "=========================================="
    log "Stopping services for consistent backup..."
    log "Service stop mode: $STOP_MODE"
    log "=========================================="

    local stopped_services=()

    # Collect multi-instance services keyed by base app
    declare -A multi_instances
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        # Extract base app name: sonarr-4k@user -> sonarr
        local base="${svc%%-*}"
        multi_instances["$base"]+="${svc} "
    done < <(discover_multi_instance_services)

    # Stop services in defined order
    for app in "${SERVICE_STOP_ORDER[@]}"; do
        # Skip apps not in SERVICE_TYPES (safety check)
        [[ -z "${SERVICE_TYPES[$app]:-}" ]] && continue

        # Skip rclone-zurg — always keep running
        [[ "$app" == "rclone-zurg" ]] && continue

        # In critical mode, only stop SQLite-backed services
        if [[ "$STOP_MODE" == "critical" && -z "${SERVICE_STOP_CRITICAL[$app]:-}" ]]; then
            continue
        fi

        # Stop the base service
        # Always attempt stop for critical services — handles crash-looping
        # services that appear briefly inactive between restarts. systemctl
        # stop on an already-inactive service is a harmless no-op.
        local service
        service=$(get_service_name "$app")
        local was_active=false
        is_service_active "$service" && was_active=true
        if [[ "$was_active" == true ]] \
            || [[ "$STOP_MODE" == "critical" && -n "${SERVICE_STOP_CRITICAL[$app]:-}" ]]; then
            if systemctl stop "$service" 2>/dev/null; then
                if [[ "$was_active" == true ]]; then
                    log "  Stopping: $service"
                    stopped_services+=("$service")
                elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
                    # Mask to truly prevent restarts during backup
                    systemctl mask --runtime "$service" 2>/dev/null || true
                    log "  Stopping: $service (was inactive/failed — masked to prevent restarts)"
                    stopped_services+=("$service")
                fi
            fi
        fi

        # Kill any stray processes that escaped the cgroup
        kill_stray_arr_processes "$app"

        # Stop multi-instance services after their base app
        if [[ "$app" == "sonarr" || "$app" == "radarr" || "$app" == "bazarr" ]]; then
            for mi_svc in ${multi_instances["$app"]:-}; do
                [[ -z "$mi_svc" ]] && continue
                local mi_was_active=false
                is_service_active "$mi_svc" && mi_was_active=true
                if [[ "$mi_was_active" == true ]] \
                    || [[ "$STOP_MODE" == "critical" && -n "${SERVICE_STOP_CRITICAL[$app]:-}" ]]; then
                    if systemctl stop "$mi_svc" 2>/dev/null; then
                        if [[ "$mi_was_active" == true ]]; then
                            log "  Stopping: $mi_svc (multi-instance)"
                            stopped_services+=("$mi_svc")
                        elif systemctl is-enabled --quiet "$mi_svc" 2>/dev/null; then
                            systemctl mask --runtime "$mi_svc" 2>/dev/null || true
                            log "  Stopping: $mi_svc (multi-instance, was inactive/failed — masked)"
                            stopped_services+=("$mi_svc")
                        fi
                    fi
                    kill_stray_arr_processes "$mi_svc"
                fi
            done
        fi
    done

    sleep 5
    log "Stopped ${#stopped_services[@]} services"
    printf '%s\n' "${stopped_services[@]}" >"$STOPPED_SERVICES_FILE"
}

start_services() {
    log "=========================================="
    log "Restarting services..."
    log "=========================================="

    [[ ! -f "$STOPPED_SERVICES_FILE" ]] && {
        log "WARNING: No stopped services list"
        return
    }

    # Read services into array and reverse for start order
    local services=()
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        services+=("$service")
    done <"$STOPPED_SERVICES_FILE"

    local failed=()
    # Start in reverse order (infrastructure first, consumers last)
    for ((i = ${#services[@]} - 1; i >= 0; i--)); do
        local service="${services[$i]}"
        # Unmask in case we masked it during stop (runtime masks only)
        systemctl unmask "$service" 2>/dev/null || true
        log "  Starting: $service"
        systemctl start "$service" 2>/dev/null || failed+=("$service")
    done

    rm -f "$STOPPED_SERVICES_FILE"
    sleep 10

    # Retry pass: some services (notably emby-server, radarr-4k, nzbdav) can
    # transiently fail their first post-backup start with EADDRINUSE because a
    # client process (autopulse, decypharr, NzbWebDAV) still holds the port
    # in CLOSE_WAIT/FIN_WAIT_2 from before the stop. Without Restart=on-failure
    # on the unit they would stay down silently.
    # We re-check each stopped service and retry up to 3 times with backoff.
    local not_running=()
    for service in "${services[@]}"; do
        is_service_active "$service" || not_running+=("$service")
    done

    if [[ ${#not_running[@]} -gt 0 ]]; then
        log "Retry pass: ${#not_running[@]} service(s) not running after first start"
        local attempt
        for attempt in 1 2 3; do
            local still_down=()
            for service in "${not_running[@]}"; do
                is_service_active "$service" && continue
                log "  Retry $attempt/3: $service"
                systemctl reset-failed "$service" 2>/dev/null || true
                systemctl start "$service" 2>/dev/null || true
                still_down+=("$service")
            done
            not_running=("${still_down[@]}")
            [[ ${#not_running[@]} -eq 0 ]] && break
            sleep $((attempt * 10))
            # Re-filter: anything that came up during the sleep is no longer down
            local check_again=()
            for service in "${not_running[@]}"; do
                is_service_active "$service" || check_again+=("$service")
            done
            not_running=("${check_again[@]}")
            [[ ${#not_running[@]} -eq 0 ]] && break
        done
    fi

    log "Service status:"
    local final_down=()
    for service in "${services[@]}"; do
        if is_service_active "$service"; then
            log "  Running: $service"
        else
            log "  NOT running: $service"
            final_down+=("$service")
        fi
    done

    if [[ ${#failed[@]} -gt 0 || ${#final_down[@]} -gt 0 ]]; then
        # Merge initial start failures with services that never came up after retries.
        local all_failed
        all_failed=$(printf '%s\n' "${failed[@]}" "${final_down[@]}" | sort -u | tr '\n' ' ')
        log "WARNING: Failed to start: $all_failed"
        _notify "Borg Backup - Service Restart Failed" \
            "Failed to restart services on $(hostname): $all_failed" "error"
    fi
}

#===============================================================================
# CLEANUP TRAP
#===============================================================================

# Script-level state for cleanup
_heartbeat_pid=""
_borg_output_file=""
_size_excludes_file=""
_backup_running=""

cleanup() {
    local exit_code=$?

    # Stop heartbeat if running
    if [[ -n "$_heartbeat_pid" ]]; then
        kill "$_heartbeat_pid" 2>/dev/null
        wait "$_heartbeat_pid" 2>/dev/null || true
        _heartbeat_pid=""
    fi
    # Clean temp files
    [[ -n "$_borg_output_file" ]] && rm -f "$_borg_output_file"
    [[ -n "$_size_excludes_file" ]] && rm -f "$_size_excludes_file"
    # Unmask any runtime-masked services and restart them
    if [[ -f "$STOPPED_SERVICES_FILE" ]]; then
        log "TRAP: Unmasking and restarting services after unexpected exit..."
        while IFS= read -r svc; do
            [[ -n "$svc" ]] && systemctl unmask "$svc" 2>/dev/null || true
        done <"$STOPPED_SERVICES_FILE"
        start_services
    fi
    # Resume any paused scheduled jobs
    if [[ -f "$PAUSED_JOBS_FILE" ]]; then
        log "TRAP: Resuming scheduled jobs after unexpected exit..."
        resume_scheduled_jobs
    fi
    # Send failure notification if backup was in progress and exited unexpectedly
    if [[ -n "$_backup_running" && $exit_code -ne 0 ]]; then
        log "TRAP: Backup exited unexpectedly (exit: ${exit_code})"
        healthcheck "/fail"
        _notify "Borg Backup FAILED" \
            "Backup crashed on $(hostname) (exit: ${exit_code})\nThe backup process terminated unexpectedly." "error"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

#===============================================================================
# LOG ROTATION
#===============================================================================

rotate_log() {
    if [[ -f "$LOGFILE" ]]; then
        local size
        size=$(stat -c%s "$LOGFILE" 2>/dev/null || stat -f%z "$LOGFILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt 10485760 ]]; then
            mv "$LOGFILE" "${LOGFILE}.1"
        fi
    fi
}

#===============================================================================
# CLI FUNCTIONS
#===============================================================================

cmd_list() {
    borg list
}

cmd_info() {
    borg info
}

cmd_check() {
    borg check --show-rc
}

cmd_verify() {
    log "Starting full data verification (this may take a long time)..."
    borg check --verify-data --show-rc 2>&1 | tee -a "$LOGFILE"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        log "Verification passed: repository and data integrity OK"
    elif [[ $rc -eq 1 ]]; then
        log "WARNING: Verification completed with warnings (rc=$rc)"
    else
        log "ERROR: Verification failed (rc=$rc)"
    fi
    return $rc
}

cmd_services() {
    echo "=== Standard services ==="
    for app in "${SERVICE_STOP_ORDER[@]}"; do
        [[ -z "${SERVICE_TYPES[$app]:-}" ]] && continue
        [[ "$app" == "rclone-zurg" ]] && continue
        local service
        service=$(get_service_name "$app")
        local state="inactive"
        is_service_active "$service" && state="active"
        printf "  %-30s %s\n" "$service" "$state"
    done

    echo ""
    echo "=== Multi-instance services ==="
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        local state="inactive"
        is_service_active "$svc" && state="active"
        printf "  %-30s %s\n" "$svc" "$state"
    done < <(discover_multi_instance_services)

    echo ""
    echo "=== Never stopped ==="
    for app in rclone-zurg organizr nextcloud; do
        if [[ -n "${SERVICE_TYPES[$app]:-}" ]]; then
            local service
            service=$(get_service_name "$app")
            local state="inactive"
            is_service_active "$service" && state="active"
            printf "  %-30s %s (protected)\n" "$service" "$state"
        fi
    done
}

cmd_dry_run() {
    log "DRY RUN: Showing what would be backed up..."

    if [[ ! -f "$EXCLUDES_FILE" ]]; then
        log "ERROR: Excludes file not found: $EXCLUDES_FILE"
        exit 1
    fi

    _size_excludes_file=$(mktemp "${TMPDIR:-/tmp}/swizzin-size-excludes.XXXXXX")
    _generate_size_excludes "$SYMLINKS_SIZE_LIMIT" "$_size_excludes_file"

    borg create \
        --verbose \
        --stats \
        --show-rc \
        --dry-run \
        --list \
        --compression auto,zstd,6 \
        --one-file-system \
        --exclude-caches \
        --pattern '+sh:home/*/.config/zurg/data/*.zurgtorrent' \
        --pattern '+sh:opt/huntarr/data/backups/**' \
        --exclude-from "$EXCLUDES_FILE" \
        --exclude-from "$_size_excludes_file" \
        \
        ::"${HOSTNAME}-dry-run" \
        \
        / \
        /boot \
        /boot/efi \
        /mnt/symlinks \
        2>&1 | tee -a "$LOGFILE"

    rm -f "$_size_excludes_file"
    _size_excludes_file=""
}

cmd_backup() {
    _backup_running=1

    local start_time
    start_time=$(date +%s)
    local archive_name
    archive_name="${HOSTNAME}-$(date +%Y-%m-%d_%H:%M)"

    log "=========================================="
    log "Starting Borg backup to remote repository"
    log "=========================================="
    log "User: $SWIZZIN_USER"
    log "Zurg: ${ZURG_DIR:-N/A}"
    log "Archive: $archive_name"

    healthcheck "/start"
    _notify "Borg Backup Started" \
        "Backup started on $(hostname)\nArchive: $archive_name" "info"

    # Show discovered multi-instance services
    log "Multi-instance services:"
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && log "  - $svc"
    done < <(discover_multi_instance_services)

    _capture_system_state
    pause_scheduled_jobs
    stop_services

    #===========================================================================
    # CREATE BACKUP
    # Note: /mnt/symlinks is explicitly included (contains arr root folder symlinks)
    #===========================================================================

    if [[ ! -f "$EXCLUDES_FILE" ]]; then
        log "ERROR: Excludes file not found: $EXCLUDES_FILE"
        exit 1
    fi

    log "Phase 1/3: Creating backup archive..."
    local phase1_start
    phase1_start=$(date +%s)

    # Break any stale remote lock. The local flock guarantees no concurrent
    # local run, so any existing remote lock is leftover from a crash/disconnect.
    borg break-lock 2>/dev/null && log "Cleared stale repo lock" || true

    # Generate size-based excludes for /mnt/symlinks
    _size_excludes_file=$(mktemp "${TMPDIR:-/tmp}/swizzin-size-excludes.XXXXXX")
    _generate_size_excludes "$SYMLINKS_SIZE_LIMIT" "$_size_excludes_file"

    # Start heartbeat if configured
    if [[ "${PROGRESS_INTERVAL:-0}" -gt 0 ]]; then
        _progress_heartbeat "$phase1_start" "$PROGRESS_INTERVAL" &
        _heartbeat_pid=$!
    fi

    _borg_output_file=$(mktemp "${TMPDIR:-/tmp}/swizzin-borg-output.XXXXXX")

    set +e
    if [[ -t 2 ]]; then
        # Interactive: show borg progress bar on terminal, capture stats to file
        borg create \
            --progress \
            --stats \
            --show-rc \
            --compression auto,zstd,6 \
            --one-file-system \
            --exclude-caches \
            --pattern '+sh:home/*/.config/zurg/data/*.zurgtorrent' \
            --pattern '+sh:opt/huntarr/data/backups/**' \
            --exclude-from "$EXCLUDES_FILE" \
            --exclude-from "$_size_excludes_file" \
            \
            ::"$archive_name" \
            \
            / \
            /boot \
            /boot/efi \
            /mnt/symlinks \
            2> >(tee "$_borg_output_file") \
            | tee -a "$LOGFILE"
    else
        # Non-interactive: stream verbose output to log, capture stats
        borg create \
            --verbose \
            --stats \
            --show-rc \
            --compression auto,zstd,6 \
            --one-file-system \
            --exclude-caches \
            --pattern '+sh:home/*/.config/zurg/data/*.zurgtorrent' \
            --pattern '+sh:opt/huntarr/data/backups/**' \
            --exclude-from "$EXCLUDES_FILE" \
            --exclude-from "$_size_excludes_file" \
            \
            ::"$archive_name" \
            \
            / \
            /boot \
            /boot/efi \
            /mnt/symlinks \
            2>&1 | tee -a "$LOGFILE" | tee "$_borg_output_file"
    fi
    backup_exit=${PIPESTATUS[0]}
    set -e

    # Stop heartbeat
    if [[ -n "$_heartbeat_pid" ]]; then
        kill "$_heartbeat_pid" 2>/dev/null
        wait "$_heartbeat_pid" 2>/dev/null || true
        _heartbeat_pid=""
    fi

    local borg_output
    borg_output=$(<"$_borg_output_file")
    rm -f "$_borg_output_file"
    _borg_output_file=""
    rm -f "$_size_excludes_file"
    _size_excludes_file=""

    log "Phase 1/3: Archive created ($(_format_duration $(($(date +%s) - phase1_start))))"

    start_services
    resume_scheduled_jobs

    #===========================================================================
    # PRUNE & COMPACT (skip if borg create was interrupted by signal)
    #===========================================================================

    local prune_exit=0
    local compact_exit=0

    if [[ $backup_exit -ge 2 ]]; then
        if [[ $backup_exit -ge 128 ]]; then
            log "Skipping prune and compact — backup was interrupted (signal $((backup_exit - 128)))"
        else
            log "Skipping prune and compact — backup failed (exit: $backup_exit)"
        fi
    elif [[ $backup_exit -eq 1 ]]; then
        log "Backup completed with warnings (rc 1) — continuing with prune and compact"
    else
        log "Phase 2/3: Pruning old archives..."
        local phase2_start
        phase2_start=$(date +%s)

        borg prune \
            --verbose --list --show-rc \
            --glob-archives "${HOSTNAME}-*" \
            --keep-daily "$KEEP_DAILY" \
            --keep-weekly "$KEEP_WEEKLY" \
            --keep-monthly "$KEEP_MONTHLY" \
            --keep-yearly "$KEEP_YEARLY" \
            2>&1 | tee -a "$LOGFILE"
        prune_exit=${PIPESTATUS[0]}

        log "Phase 2/3: Prune complete ($(_format_duration $(($(date +%s) - phase2_start))))"

        log "Phase 3/3: Compacting repository..."
        local phase3_start
        phase3_start=$(date +%s)

        borg compact --show-rc 2>&1 | tee -a "$LOGFILE"
        compact_exit=${PIPESTATUS[0]}

        log "Phase 3/3: Compact complete ($(_format_duration $(($(date +%s) - phase3_start))))"
    fi

    #===========================================================================
    # RESULT
    #===========================================================================

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_min=$((duration / 60))
    local duration_sec=$((duration % 60))

    global_exit=$((backup_exit > prune_exit ? backup_exit : prune_exit))
    global_exit=$((global_exit > compact_exit ? global_exit : compact_exit))

    # Parse stats from borg output
    local stats_summary=""
    if [[ -n "${borg_output:-}" ]]; then
        local orig_size comp_size dedup_size nfiles
        orig_size=$(echo "$borg_output" | grep -oP 'This archive:\s+\K[\d.]+ [A-Za-z]+' | head -1) || true
        comp_size=$(echo "$borg_output" | grep -oP 'Compressed size:\s+\K[\d.]+ [A-Za-z]+') || true
        dedup_size=$(echo "$borg_output" | grep -oP 'Deduplicated size:\s+\K[\d.]+ [A-Za-z]+') || true
        nfiles=$(echo "$borg_output" | grep -oP 'Number of files:\s+\K[\d]+') || true
        stats_summary="Duration: ${duration_min}m ${duration_sec}s"
        [[ -n "${orig_size:-}" ]] && stats_summary+="\nOriginal size: $orig_size"
        [[ -n "${comp_size:-}" ]] && stats_summary+="\nCompressed: $comp_size"
        [[ -n "${dedup_size:-}" ]] && stats_summary+="\nDeduplicated: $dedup_size"
        [[ -n "${nfiles:-}" ]] && stats_summary+="\nFiles: $nfiles"
    else
        stats_summary="Duration: ${duration_min}m ${duration_sec}s"
    fi

    if [[ ${global_exit} -eq 0 ]]; then
        log "=========================================="
        log "Backup completed SUCCESSFULLY"
        log "=========================================="
        healthcheck ""
        _notify "Borg Backup Success" \
            "Backup completed on $(hostname)\nArchive: $archive_name\n$stats_summary" "info"
    elif [[ ${global_exit} -eq 1 ]]; then
        log "Backup completed with WARNINGS"
        healthcheck "/1"
        _notify "Borg Backup Warning" \
            "Backup completed with warnings on $(hostname)\nArchive: $archive_name\n$stats_summary" "warning"
    else
        log "Backup FAILED (exit: ${global_exit})"
        healthcheck "/fail"
        _notify "Borg Backup FAILED" \
            "Backup failed on $(hostname) (exit: ${global_exit})\nArchive: $archive_name\n$stats_summary" "error"
    fi

    borg info 2>&1 | tee -a "$LOGFILE"
    log "Backup process finished"
    _backup_running=""
    exit ${global_exit}
}

#===============================================================================
# MAIN
#===============================================================================

[[ $EUID -ne 0 ]] && {
    echo "Must run as root"
    exit 1
}

mkdir -p "$(dirname "$LOGFILE")"
rotate_log

# Parse CLI arguments
case "${1:-}" in
    --dry-run)
        cmd_dry_run
        ;;
    --list)
        cmd_list
        ;;
    --info)
        cmd_info
        ;;
    --check)
        cmd_check
        ;;
    --verify)
        exec 200>"$LOCKFILE"
        flock -n 200 || {
            log "ERROR: Another backup/verify running"
            exit 1
        }
        cmd_verify
        ;;
    --services)
        cmd_services
        ;;
    --help | -h)
        echo "Usage: $(basename "$0") [OPTION]"
        echo ""
        echo "Options:"
        echo "  (none)       Run full backup (default)"
        echo "  --dry-run    Show what would be backed up"
        echo "  --list       List archives"
        echo "  --info       Show repository info"
        echo "  --check      Run borg check"
        echo "  --verify     Run borg check --verify-data (slow, full integrity)"
        echo "  --services   List discovered services (includes multi-instance)"
        echo "  --help       Show this help"
        ;;
    "")
        # Default: run full backup with lock
        exec 200>"$LOCKFILE"
        flock -n 200 || {
            log "ERROR: Another backup running"
            exit 1
        }
        cmd_backup
        ;;
    *)
        echo "Unknown option: $1"
        echo "Run '$(basename "$0") --help' for usage"
        exit 1
        ;;
esac
