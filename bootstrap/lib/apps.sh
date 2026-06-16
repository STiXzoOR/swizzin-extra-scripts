#!/bin/bash
# apps.sh - App bundles, script runner, order enforcement
# Part of swizzin-scripts bootstrap

# ==============================================================================
# Script Repository Location
# ==============================================================================

# Where the swizzin-scripts repo is cloned/downloaded
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ==============================================================================
# App Bundles
# ==============================================================================

declare -A APP_BUNDLES

# Core: Just Swizzin base
APP_BUNDLES[core]="nginx panel"

# Streaming: Media servers + requests
APP_BUNDLES[streaming]="plex emby jellyfin seerr"

# Arr Stack: Media management
APP_BUNDLES[arr]="sonarr radarr bazarr prowlarr jackett"

# Debrid: Real-Debrid integration
APP_BUNDLES[debrid]="zurg decypharr"

# Helpers: Additional tools
APP_BUNDLES[helpers]="huntarr cleanuparr byparr notifiarr filebrowser librespeed libretranslate"

# Full Stack: Everything
APP_BUNDLES[full]="plex emby jellyfin seerr sonarr radarr bazarr prowlarr jackett zurg decypharr huntarr cleanuparr byparr notifiarr filebrowser librespeed libretranslate organizr"

# ==============================================================================
# Installation Order
# ==============================================================================

# Order matters! Dependencies and conflicts handled here
INSTALL_ORDER=(
    # Phase 1: Swizzin base (handled separately)

    # Phase 2: Media servers (emby before jellyfin for port conflict)
    "plex"
    "emby"
    "jellyfin"
    "airsonic"
    "calibreweb"
    "mango"
    "navidrome"
    "tautulli"
    "seerr"

    # Phase 3: Arr stack (multi-instance capable)
    "sonarr"
    "radarr"
    "bazarr"
    "lidarr"
    "prowlarr"
    "jackett"
    "autobrr"
    "autodl"
    "medusa"
    "mylar"
    "ombi"
    "sickchill"
    "sickgear"

    # Phase 4: Torrent clients
    "rtorrent"
    "rutorrent"
    "flood"
    "qbittorrent"
    "deluge"
    "transmission"

    # Phase 5: Usenet clients
    "sabnzbd"
    "nzbget"
    "nzbhydra2"

    # Phase 6: Debrid / Cloud (zurg before decypharr)
    "rclone"
    "zurg"
    "decypharr"

    # Phase 7: Helpers (from this repo)
    "huntarr"
    "cleanuparr"
    "byparr"
    "notifiarr"
    "subgen"
    "lingarr"
    "libretranslate"

    # Phase 8: Backup & Sync
    "nextcloud"
    "syncthing"
    "btsync"
    "vsftpd"

    # Phase 9: IRC
    "lounge"
    "quassel"
    "znc"

    # Phase 10: Utilities
    "ffmpeg"
    "librespeed"
    "netdata"
    "pyload"
    "quota"
    "wireguard"
    "x2go"
    "xmrig"

    # Phase 11: Web features
    "filebrowser"
    "shellinabox"
    "webmin"
    "duckdns"
    "letsencrypt"

    # Phase 12: Watchdog (after media servers)
    "emby-watchdog"

    # Phase 13: SSO Gateway (ALWAYS LAST)
    "organizr"
)

# ==============================================================================
# App Configuration
# ==============================================================================

# Which apps are from this repo vs Swizzin
declare -A APP_SOURCE
APP_SOURCE[plex]="repo"        # Uses plex.sh from this repo
APP_SOURCE[emby]="repo"        # Uses emby.sh from this repo
APP_SOURCE[jellyfin]="repo"    # Uses jellyfin.sh from this repo
APP_SOURCE[sonarr]="repo"      # Uses sonarr.sh (multi-instance)
APP_SOURCE[radarr]="repo"      # Uses radarr.sh (multi-instance)
APP_SOURCE[bazarr]="repo"      # Uses bazarr.sh (multi-instance)
APP_SOURCE[prowlarr]="swizzin" # Uses box install prowlarr
APP_SOURCE[jackett]="swizzin"  # Uses box install jackett
APP_SOURCE[zurg]="repo"
APP_SOURCE[decypharr]="repo"
APP_SOURCE[huntarr]="repo"
APP_SOURCE[cleanuparr]="repo"
APP_SOURCE[byparr]="repo"
APP_SOURCE[notifiarr]="repo"
APP_SOURCE[subgen]="repo"
APP_SOURCE[lingarr]="repo"
APP_SOURCE[libretranslate]="repo"
APP_SOURCE[organizr]="repo"
APP_SOURCE[seerr]="repo"
APP_SOURCE[emby-watchdog]="repo"
APP_SOURCE[nginx]="swizzin"
APP_SOURCE[panel]="repo"

# All other Swizzin apps default to swizzin source
APP_SOURCE[airsonic]="swizzin"
APP_SOURCE[autobrr]="swizzin"
APP_SOURCE[autodl]="swizzin"
APP_SOURCE[btsync]="swizzin"
APP_SOURCE[calibreweb]="swizzin"
APP_SOURCE[deluge]="swizzin"
APP_SOURCE[duckdns]="swizzin"
APP_SOURCE[ffmpeg]="swizzin"
APP_SOURCE[filebrowser]="swizzin"
APP_SOURCE[flood]="swizzin"
APP_SOURCE[letsencrypt]="swizzin"
APP_SOURCE[librespeed]="swizzin"
APP_SOURCE[lidarr]="swizzin"
APP_SOURCE[lounge]="swizzin"
APP_SOURCE[mango]="swizzin"
APP_SOURCE[medusa]="swizzin"
APP_SOURCE[mylar]="swizzin"
APP_SOURCE[navidrome]="swizzin"
APP_SOURCE[netdata]="swizzin"
APP_SOURCE[nextcloud]="swizzin"
APP_SOURCE[nzbget]="swizzin"
APP_SOURCE[nzbhydra2]="swizzin"
APP_SOURCE[ombi]="swizzin"
APP_SOURCE[pyload]="swizzin"
APP_SOURCE[qbittorrent]="swizzin"
APP_SOURCE[quassel]="swizzin"
APP_SOURCE[quota]="swizzin"
APP_SOURCE[rclone]="swizzin"
APP_SOURCE[rtorrent]="swizzin"
APP_SOURCE[rutorrent]="swizzin"
APP_SOURCE[sabnzbd]="swizzin"
APP_SOURCE[shellinabox]="swizzin"
APP_SOURCE[sickchill]="swizzin"
APP_SOURCE[sickgear]="swizzin"
APP_SOURCE[syncthing]="swizzin"
APP_SOURCE[tautulli]="swizzin"
APP_SOURCE[transmission]="swizzin"
APP_SOURCE[vsftpd]="swizzin"
APP_SOURCE[webmin]="swizzin"
APP_SOURCE[wireguard]="swizzin"
APP_SOURCE[x2go]="swizzin"
APP_SOURCE[xmrig]="swizzin"
APP_SOURCE[znc]="swizzin"

# Script files for repo apps
declare -A APP_SCRIPT
APP_SCRIPT[plex]="plex.sh"
APP_SCRIPT[emby]="emby.sh"
APP_SCRIPT[jellyfin]="jellyfin.sh"
APP_SCRIPT[sonarr]="sonarr.sh"
APP_SCRIPT[radarr]="radarr.sh"
APP_SCRIPT[bazarr]="bazarr.sh"
APP_SCRIPT[zurg]="zurg.sh"
APP_SCRIPT[decypharr]="decypharr.sh"
APP_SCRIPT[huntarr]="huntarr.sh"
APP_SCRIPT[cleanuparr]="cleanuparr.sh"
APP_SCRIPT[byparr]="byparr.sh"
APP_SCRIPT[notifiarr]="notifiarr.sh"
APP_SCRIPT[subgen]="subgen.sh"
APP_SCRIPT[lingarr]="lingarr.sh"
APP_SCRIPT[libretranslate]="libretranslate.sh"
APP_SCRIPT[organizr]="organizr.sh"
APP_SCRIPT[seerr]="seerr.sh"
APP_SCRIPT[emby-watchdog]="emby-watchdog.sh"
APP_SCRIPT[panel]="panel.sh"

# ==============================================================================
# App Selection
# ==============================================================================

select_apps() {
    echo_header "App Selection"

    # Check if whiptail is available
    if ! command -v whiptail &>/dev/null; then
        echo_warn "whiptail not found, using fallback menu"
        _select_apps_fallback
        return
    fi

    # Bundle selection using whiptail radiolist
    local choice
    choice=$(whiptail --title "App Selection" \
        --radiolist "Select installation bundle:\n(Use arrow keys and space to select)" \
        20 70 6 \
        "core" "Core only - nginx + panel" OFF \
        "streaming" "Streaming - Core + Plex + Emby + Jellyfin" OFF \
        "arr" "Arr Stack - Core + Sonarr + Radarr + Bazarr + Prowlarr + Jackett" OFF \
        "debrid" "Debrid - Core + Zurg + Decypharr" OFF \
        "full" "Full Stack - Everything (recommended)" ON \
        "custom" "Custom - Choose individual apps" OFF \
        3>&1 1>&2 2>&3) || {
        echo_error "Bundle selection cancelled"
        exit 1
    }

    case "$choice" in
        core) SELECTED_APPS=(${APP_BUNDLES[core]}) ;;
        streaming) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[streaming]}) ;;
        arr) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[arr]}) ;;
        debrid) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[debrid]}) ;;
        full) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[full]}) ;;
        custom) select_custom_apps ;;
        *) echo_error "Invalid choice"; exit 1 ;;
    esac

    # Remove duplicates while preserving order
    SELECTED_APPS=($(echo "${SELECTED_APPS[@]}" | tr ' ' '\n' | awk '!seen[$0]++'))

    echo_info "Selected apps: ${SELECTED_APPS[*]}"

    # Subdomain configuration for media servers
    _select_subdomain_apps

    # Multi-instance configuration for arr apps
    _select_multi_instances
}

_select_apps_fallback() {
    echo "Select installation bundle:"
    echo ""
    echo "  1) Core only      - nginx + panel"
    echo "  2) Streaming      - Core + Plex + Emby + Jellyfin"
    echo "  3) Arr Stack      - Core + Sonarr + Radarr + Bazarr + Prowlarr + Jackett"
    echo "  4) Debrid         - Core + Zurg + Decypharr"
    echo "  5) Full Stack     - Everything (recommended)"
    echo "  6) Custom         - Choose individual apps"
    echo ""

    local choice
    read -rp "Choice [1-6]: " choice </dev/tty

    case "$choice" in
        1) SELECTED_APPS=(${APP_BUNDLES[core]}) ;;
        2) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[streaming]}) ;;
        3) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[arr]}) ;;
        4) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[debrid]}) ;;
        5) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[full]}) ;;
        6) select_custom_apps ;;
        *) echo_error "Invalid choice"; exit 1 ;;
    esac

    # Remove duplicates while preserving order
    SELECTED_APPS=($(echo "${SELECTED_APPS[@]}" | tr ' ' '\n' | awk '!seen[$0]++'))

    echo_info "Selected apps: ${SELECTED_APPS[*]}"

    # Subdomain and multi-instance config
    _select_subdomain_apps
    _select_multi_instances
}

_select_subdomain_apps() {
    # Build list of subdomain-capable apps that are selected
    # Note: panel is always included since it's part of core
    local subdomain_capable=("panel")
    for app in plex emby jellyfin organizr seerr; do
        if [[ " ${SELECTED_APPS[*]} " =~ " ${app} " ]]; then
            subdomain_capable+=("$app")
        fi
    done

    if [[ ${#subdomain_capable[@]} -eq 0 ]]; then
        return
    fi

    if command -v whiptail &>/dev/null; then
        # Build whiptail options
        local options=()
        for app in "${subdomain_capable[@]}"; do
            options+=("$app" "" "OFF")
        done

        local selected
        selected=$(whiptail --title "Subdomain Configuration" \
            --checklist "Select apps to configure with subdomain:\n(Space to toggle, Enter to confirm)" \
            20 60 ${#subdomain_capable[@]} \
            "${options[@]}" \
            3>&1 1>&2 2>&3) || true

        # Parse selected (whiptail returns "app1" "app2" format)
        selected=$(echo "$selected" | tr -d '"')
        for app in $selected; do
            SUBDOMAIN_APPS+=("$app")
        done
    else
        # Fallback to ask
        for app in "${subdomain_capable[@]}"; do
            if ask "Configure $app with subdomain?" N; then
                SUBDOMAIN_APPS+=("$app")
            fi
        done
    fi
}

_select_multi_instances() {
    for app in sonarr radarr bazarr; do
        if [[ " ${SELECTED_APPS[*]} " =~ " ${app} " ]]; then
            if ask "Add additional $app instances (e.g., 4k, anime)?" N; then
                echo_info "Enter instance names (comma-separated, e.g., 4k,anime):"
                read -rp "> " instances </dev/tty
                MULTI_INSTANCES[$app]="$instances"
            fi
        fi
    done
}

select_custom_apps() {
    echo_header "Custom App Selection"

    SELECTED_APPS=("nginx" "panel")  # Always include core

    # Check if whiptail is available
    if ! command -v whiptail &>/dev/null; then
        echo_warn "whiptail not found, using fallback menu"
        _select_custom_apps_fallback
        return
    fi

    # All apps organized by category for whiptail
    # Format: "app" "description" "ON/OFF"
    local options=(
        # Media Servers
        "plex" "Plex Media Server" "OFF"
        "emby" "Emby Media Server" "OFF"
        "jellyfin" "Jellyfin Media Server" "OFF"
        "airsonic" "Airsonic (Music Streaming)" "OFF"
        "calibreweb" "Calibre-Web (eBook Library)" "OFF"
        "mango" "Mango (Manga Reader)" "OFF"
        "navidrome" "Navidrome (Music Streaming)" "OFF"
        "tautulli" "Tautulli (Plex Monitoring)" "OFF"
        "seerr" "Seerr/Overseerr (Media Requests)" "OFF"
        # Automation / Arr Stack
        "sonarr" "Sonarr (TV Shows)" "OFF"
        "radarr" "Radarr (Movies)" "OFF"
        "bazarr" "Bazarr (Subtitles)" "OFF"
        "lidarr" "Lidarr (Music)" "OFF"
        "prowlarr" "Prowlarr (Indexer Manager)" "OFF"
        "jackett" "Jackett (Indexer Proxy)" "OFF"
        "autobrr" "Autobrr (Autodl Alternative)" "OFF"
        "autodl" "Autodl-irssi (IRC Autodl)" "OFF"
        "medusa" "Medusa (TV Shows)" "OFF"
        "mylar" "Mylar3 (Comics)" "OFF"
        "ombi" "Ombi (Media Requests)" "OFF"
        "sickchill" "SickChill (TV Shows)" "OFF"
        "sickgear" "SickGear (TV Shows)" "OFF"
        # Torrent Clients
        "qbittorrent" "qBittorrent" "OFF"
        "deluge" "Deluge" "OFF"
        "rtorrent" "rTorrent" "OFF"
        "rutorrent" "ruTorrent (rTorrent Web UI)" "OFF"
        "flood" "Flood (rTorrent Web UI)" "OFF"
        "transmission" "Transmission" "OFF"
        # Usenet Clients
        "sabnzbd" "SABnzbd" "OFF"
        "nzbget" "NZBGet" "OFF"
        "nzbhydra2" "NZBHydra2 (Usenet Indexer)" "OFF"
        # Real-Debrid / Cloud
        "zurg" "Zurg (Real-Debrid WebDAV)" "OFF"
        "decypharr" "Decypharr (Debrid Manager)" "OFF"
        "rclone" "Rclone (Cloud Storage Mount)" "OFF"
        # Helpers (from this repo)
        "huntarr" "Huntarr (Media Discovery)" "OFF"
        "cleanuparr" "Cleanuparr (Queue Cleanup)" "OFF"
        "byparr" "Byparr (FlareSolverr Alternative)" "OFF"
        "notifiarr" "Notifiarr (Notifications)" "OFF"
        "subgen" "Subgen (Whisper Subtitles)" "OFF"
        "lingarr" "Lingarr (Subtitle Translation)" "OFF"
        "libretranslate" "LibreTranslate (Translation API)" "OFF"
        # Backup & Sync
        "nextcloud" "Nextcloud" "OFF"
        "syncthing" "Syncthing" "OFF"
        "btsync" "Resilio Sync" "OFF"
        "vsftpd" "vsftpd (FTP Server)" "OFF"
        # IRC
        "lounge" "The Lounge (IRC Client)" "OFF"
        "quassel" "Quassel (IRC Client)" "OFF"
        "znc" "ZNC (IRC Bouncer)" "OFF"
        # Utilities
        "ffmpeg" "FFmpeg" "OFF"
        "librespeed" "LibreSpeed (Speed Test)" "OFF"
        "netdata" "Netdata (Monitoring)" "OFF"
        "pyload" "pyLoad (Download Manager)" "OFF"
        "quota" "Disk Quota" "OFF"
        "wireguard" "WireGuard VPN" "OFF"
        "x2go" "X2Go (Remote Desktop)" "OFF"
        "xmrig" "XMRig (Crypto Miner)" "OFF"
        # Web Features
        "organizr" "Organizr (SSO Dashboard)" "OFF"
        "filebrowser" "FileBrowser" "OFF"
        "shellinabox" "Shell In A Box (Web Terminal)" "OFF"
        "webmin" "Webmin (Server Admin)" "OFF"
        "duckdns" "DuckDNS (Dynamic DNS)" "OFF"
        "letsencrypt" "Let's Encrypt SSL" "OFF"
    )

    local selected
    selected=$(whiptail --title "Custom App Selection" \
        --checklist "Select apps to install:\n(nginx and panel are always installed)\n\nSpace to toggle, Enter to confirm" \
        30 70 20 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) || {
        echo_info "App selection cancelled"
        exit 1
    }

    # Parse selected (whiptail returns "app1" "app2" format)
    selected=$(echo "$selected" | tr -d '"')
    for app in $selected; do
        SELECTED_APPS+=("$app")
    done
}

_select_custom_apps_fallback() {
    echo "Select apps to install (Y/n for each):"
    echo "(nginx and panel are always installed)"
    echo ""

    # -------------------------------------------------------------------------
    # Media Servers
    # -------------------------------------------------------------------------
    echo_info "=== Media Servers ==="
    local media_servers=(
        "plex:Plex Media Server"
        "emby:Emby Media Server"
        "jellyfin:Jellyfin Media Server"
        "airsonic:Airsonic (Music Streaming)"
        "calibreweb:Calibre-Web (eBook Library)"
        "mango:Mango (Manga Reader)"
        "navidrome:Navidrome (Music Streaming)"
        "tautulli:Tautulli (Plex Monitoring)"
        "seerr:Seerr/Overseerr (Media Requests)"
    )
    for app_info in "${media_servers[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Automation / Arr Stack
    # -------------------------------------------------------------------------
    echo_info "=== Automation (Arr Stack) ==="
    local automation_apps=(
        "sonarr:Sonarr (TV Shows)"
        "radarr:Radarr (Movies)"
        "bazarr:Bazarr (Subtitles)"
        "lidarr:Lidarr (Music)"
        "prowlarr:Prowlarr (Indexer Manager)"
        "jackett:Jackett (Indexer Proxy)"
        "autobrr:Autobrr (Autodl Alternative)"
        "autodl:Autodl-irssi (IRC Autodl)"
        "medusa:Medusa (TV Shows)"
        "mylar:Mylar3 (Comics)"
        "ombi:Ombi (Media Requests)"
        "sickchill:SickChill (TV Shows)"
        "sickgear:SickGear (TV Shows)"
    )
    for app_info in "${automation_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Torrent Clients
    # -------------------------------------------------------------------------
    echo_info "=== Torrent Clients ==="
    local torrent_apps=(
        "qbittorrent:qBittorrent"
        "deluge:Deluge"
        "rtorrent:rTorrent"
        "rutorrent:ruTorrent (rTorrent Web UI)"
        "flood:Flood (rTorrent Web UI)"
        "transmission:Transmission"
    )
    for app_info in "${torrent_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Usenet Clients
    # -------------------------------------------------------------------------
    echo_info "=== Usenet Clients ==="
    local usenet_apps=(
        "sabnzbd:SABnzbd"
        "nzbget:NZBGet"
        "nzbhydra2:NZBHydra2 (Usenet Indexer)"
    )
    for app_info in "${usenet_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Real-Debrid / Cloud Integration
    # -------------------------------------------------------------------------
    echo_info "=== Real-Debrid / Cloud ==="
    local debrid_apps=(
        "zurg:Zurg (Real-Debrid WebDAV)"
        "decypharr:Decypharr (Debrid Manager)"
        "rclone:Rclone (Cloud Storage Mount)"
    )
    for app_info in "${debrid_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Helpers (from this repo)
    # -------------------------------------------------------------------------
    echo_info "=== Helpers (swizzin-scripts) ==="
    local helper_apps=(
        "huntarr:Huntarr (Media Discovery)"
        "cleanuparr:Cleanuparr (Queue Cleanup)"
        "byparr:Byparr (FlareSolverr Alternative)"
        "notifiarr:Notifiarr (Notifications)"
        "subgen:Subgen (Whisper Subtitles)"
        "lingarr:Lingarr (Subtitle Translation)"
        "libretranslate:LibreTranslate (Translation API)"
    )
    for app_info in "${helper_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Backup & Sync
    # -------------------------------------------------------------------------
    echo_info "=== Backup & Sync ==="
    local backup_apps=(
        "nextcloud:Nextcloud"
        "syncthing:Syncthing"
        "btsync:Resilio Sync"
        "vsftpd:vsftpd (FTP Server)"
    )
    for app_info in "${backup_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # IRC
    # -------------------------------------------------------------------------
    echo_info "=== IRC ==="
    local irc_apps=(
        "lounge:The Lounge (IRC Client)"
        "quassel:Quassel (IRC Client)"
        "znc:ZNC (IRC Bouncer)"
    )
    for app_info in "${irc_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Utilities
    # -------------------------------------------------------------------------
    echo_info "=== Utilities ==="
    local utility_apps=(
        "ffmpeg:FFmpeg"
        "librespeed:LibreSpeed (Speed Test)"
        "netdata:Netdata (Monitoring)"
        "pyload:pyLoad (Download Manager)"
        "quota:Disk Quota"
        "wireguard:WireGuard VPN"
        "x2go:X2Go (Remote Desktop)"
        "xmrig:XMRig (Crypto Miner)"
    )
    for app_info in "${utility_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done

    echo ""

    # -------------------------------------------------------------------------
    # Web Features
    # -------------------------------------------------------------------------
    echo_info "=== Web Features ==="
    local web_apps=(
        "organizr:Organizr (SSO Dashboard)"
        "filebrowser:FileBrowser"
        "shellinabox:Shell In A Box (Web Terminal)"
        "webmin:Webmin (Server Admin)"
        "duckdns:DuckDNS (Dynamic DNS)"
        "letsencrypt:Let's Encrypt SSL"
    )
    for app_info in "${web_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"
        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done
}

# ==============================================================================
# Environment Variable Collection
# ==============================================================================

declare -A APP_ENV

collect_app_config() {
    echo_header "App Configuration"

    # Collect Zurg config if selected
    if [[ " ${SELECTED_APPS[*]} " =~ " zurg " ]]; then
        echo_info "Zurg requires Real-Debrid API token"

        if [[ -z "${APP_ENV[RD_TOKEN]:-}" ]]; then
            APP_ENV[RD_TOKEN]=$(prompt_secret "Real-Debrid API token (from https://real-debrid.com/apitoken)")
        fi

        echo ""
        if ask "Do you have the paid/sponsor version of Zurg?" N; then
            APP_ENV[ZURG_VERSION]="paid"
            APP_ENV[GITHUB_TOKEN]=$(prompt_secret "GitHub Personal Access Token (for paid Zurg)")

            # Validate token was captured
            if [[ -z "${APP_ENV[GITHUB_TOKEN]:-}" ]]; then
                echo_error "GitHub token is required for paid version"
                echo_info "Switching to free version"
                APP_ENV[ZURG_VERSION]="free"
            else
                local token_preview="${APP_ENV[GITHUB_TOKEN]:0:4}...${APP_ENV[GITHUB_TOKEN]: -4}"
                echo_info "GitHub token captured: $token_preview"
            fi
        else
            APP_ENV[ZURG_VERSION]="free"
        fi

        echo_info "Zurg version: ${APP_ENV[ZURG_VERSION]}"

        # Ask about using latest tag (pre-release) vs latest stable release
        if ask "Use latest tag instead of latest release? (recommended for newest features)" Y; then
            APP_ENV[ZURG_USE_LATEST_TAG]="true"
        fi

        APP_ENV[ZURG_MOUNT_POINT]=$(prompt_value "Zurg mount point" "/mnt/zurg")
    fi

    # Collect Notifiarr config if selected
    if [[ " ${SELECTED_APPS[*]} " =~ " notifiarr " ]]; then
        if [[ -z "${APP_ENV[DN_API_KEY]:-}" ]]; then
            APP_ENV[DN_API_KEY]=$(prompt_secret "Notifiarr API key (from notifiarr.com)")
        fi
    fi

    # Collect domain for subdomain apps
    if [[ ${#SUBDOMAIN_APPS[@]} -gt 0 ]]; then
        echo ""
        echo_info "Subdomain configuration"
        local base_domain
        base_domain=$(prompt_value "Base domain (e.g., example.com)")

        for app in "${SUBDOMAIN_APPS[@]}"; do
            local suggested="${app}.${base_domain}"
            local domain
            domain=$(prompt_value "Domain for $app" "$suggested")

            local var_name="${app^^}_DOMAIN"
            APP_ENV[$var_name]="$domain"
            APP_ENV["${app^^}_LE_INTERACTIVE"]="no"
        done
    fi
}

# ==============================================================================
# Installation Functions
# ==============================================================================

_is_swizzin_installed() {
    # Check for Swizzin installation by looking for actual files
    # Note: 'box' command may not be in PATH until new shell session
    # So we check for the actual script and directory instead
    if [[ -d /etc/swizzin ]] && [[ -f /usr/local/bin/swizzin/box ]]; then
        return 0
    fi
    return 1
}

_ensure_box_in_path() {
    # Ensure box command is available in current session
    # Swizzin adds to PATH in .bashrc but current shell may not have it
    if ! command -v box &>/dev/null; then
        if [[ -f /usr/local/bin/swizzin/box ]]; then
            export PATH="$PATH:/usr/local/bin/swizzin"
        fi
    fi
}

install_swizzin_base() {
    echo_header "Swizzin Installation"

    if _is_swizzin_installed; then
        echo_info "Swizzin already installed"

        # Ensure box is in PATH for current session
        _ensure_box_in_path

        # Check for nginx and panel
        if [[ ! -f /install/.nginx.lock ]]; then
            echo_info "Installing nginx..."
            box install nginx
        fi
        if [[ ! -f /install/.panel.lock ]]; then
            echo_info "Installing panel..."
            box install panel
        fi
        return 0
    fi

    echo_info "Running Swizzin installer..."
    echo_warn "You will be prompted for username and password"
    echo_info "Make sure to select at least: nginx, panel"
    echo ""

    if ask "Ready to run Swizzin installer?" Y; then
        bash <(curl -sL git.io/swizzin)
    else
        echo_error "Swizzin installation required"
        exit 1
    fi

    # Verify installation - check if swizzin files exist
    if ! _is_swizzin_installed; then
        echo_error "Swizzin installation failed"
        exit 1
    fi

    # Ensure box is in PATH for current session
    _ensure_box_in_path

    echo_success "Swizzin installed"
}

install_app() {
    local app="$1"
    local source="${APP_SOURCE[$app]:-swizzin}"

    # Skip if already installed
    local lock_file="/install/.${app}.lock"
    if [[ -f "$lock_file" ]]; then
        echo_info "$app already installed"
        return 0
    fi

    echo_info "Installing $app..."
    echo ""

    if [[ "$source" == "swizzin" ]]; then
        # Install via box - show output for interactive prompts
        box install "$app" 2>&1 | tee -a "$LOG_FILE"
        local result=${PIPESTATUS[0]}
    else
        # Install via repo script
        local script="${APP_SCRIPT[$app]}"
        local script_path="$SCRIPTS_DIR/$script"

        if [[ ! -f "$script_path" ]]; then
            echo_error "Script not found: $script_path"
            return 1
        fi

        # Export environment variables for this app
        _export_app_env "$app"

        # Run the script - show output for interactive prompts
        bash "$script_path" 2>&1 | tee -a "$LOG_FILE"
        local result=${PIPESTATUS[0]}
    fi

    echo ""

    # Check if lock file was created (better indicator than exit code)
    if [[ -f "/install/.${app}.lock" ]]; then
        echo_success "$app installed"
        return 0
    else
        echo_error "$app installation may have failed"
        echo_warn "Check $LOG_FILE for details"
        return 1
    fi
}

_export_app_env() {
    local app="$1"

    # Export relevant environment variables
    case "$app" in
        zurg)
            [[ -n "${APP_ENV[RD_TOKEN]:-}" ]] && export RD_TOKEN="${APP_ENV[RD_TOKEN]}"
            [[ -n "${APP_ENV[ZURG_VERSION]:-}" ]] && export ZURG_VERSION="${APP_ENV[ZURG_VERSION]}"
            [[ -n "${APP_ENV[GITHUB_TOKEN]:-}" ]] && export GITHUB_TOKEN="${APP_ENV[GITHUB_TOKEN]}"
            [[ -n "${APP_ENV[ZURG_MOUNT_POINT]:-}" ]] && export ZURG_MOUNT_POINT="${APP_ENV[ZURG_MOUNT_POINT]}"
            [[ -n "${APP_ENV[ZURG_USE_LATEST_TAG]:-}" ]] && export ZURG_USE_LATEST_TAG="${APP_ENV[ZURG_USE_LATEST_TAG]}"
            [[ -n "${APP_ENV[ZURG_UPGRADE]:-}" ]] && export ZURG_UPGRADE="${APP_ENV[ZURG_UPGRADE]}"
            ;;
        decypharr)
            [[ -n "${APP_ENV[ZURG_MOUNT_POINT]:-}" ]] && export DECYPHARR_MOUNT_PATH="${APP_ENV[ZURG_MOUNT_POINT]}"
            ;;
        notifiarr)
            [[ -n "${APP_ENV[DN_API_KEY]:-}" ]] && export DN_API_KEY="${APP_ENV[DN_API_KEY]}"
            ;;
        plex)
            [[ -n "${APP_ENV[PLEX_DOMAIN]:-}" ]] && export PLEX_DOMAIN="${APP_ENV[PLEX_DOMAIN]}"
            [[ -n "${APP_ENV[PLEX_LE_INTERACTIVE]:-}" ]] && export PLEX_LE_INTERACTIVE="${APP_ENV[PLEX_LE_INTERACTIVE]}"
            ;;
        emby)
            [[ -n "${APP_ENV[EMBY_DOMAIN]:-}" ]] && export EMBY_DOMAIN="${APP_ENV[EMBY_DOMAIN]}"
            [[ -n "${APP_ENV[EMBY_LE_INTERACTIVE]:-}" ]] && export EMBY_LE_INTERACTIVE="${APP_ENV[EMBY_LE_INTERACTIVE]}"
            ;;
        jellyfin)
            [[ -n "${APP_ENV[JELLYFIN_DOMAIN]:-}" ]] && export JELLYFIN_DOMAIN="${APP_ENV[JELLYFIN_DOMAIN]}"
            [[ -n "${APP_ENV[JELLYFIN_LE_INTERACTIVE]:-}" ]] && export JELLYFIN_LE_INTERACTIVE="${APP_ENV[JELLYFIN_LE_INTERACTIVE]}"
            ;;
        organizr)
            [[ -n "${APP_ENV[ORGANIZR_DOMAIN]:-}" ]] && export ORGANIZR_DOMAIN="${APP_ENV[ORGANIZR_DOMAIN]}"
            [[ -n "${APP_ENV[ORGANIZR_LE_INTERACTIVE]:-}" ]] && export ORGANIZR_LE_INTERACTIVE="${APP_ENV[ORGANIZR_LE_INTERACTIVE]}"
            ;;
        seerr)
            [[ -n "${APP_ENV[SEERR_DOMAIN]:-}" ]] && export SEERR_DOMAIN="${APP_ENV[SEERR_DOMAIN]}"
            [[ -n "${APP_ENV[SEERR_LE_INTERACTIVE]:-}" ]] && export SEERR_LE_INTERACTIVE="${APP_ENV[SEERR_LE_INTERACTIVE]}"
            ;;
        panel)
            [[ -n "${APP_ENV[PANEL_DOMAIN]:-}" ]] && export PANEL_DOMAIN="${APP_ENV[PANEL_DOMAIN]}"
            [[ -n "${APP_ENV[PANEL_LE_INTERACTIVE]:-}" ]] && export PANEL_LE_INTERACTIVE="${APP_ENV[PANEL_LE_INTERACTIVE]}"
            ;;
    esac
}

install_subdomain() {
    local app="$1"

    if [[ ! " ${SUBDOMAIN_APPS[*]} " =~ " ${app} " ]]; then
        return 0
    fi

    echo_info "Configuring $app subdomain..."
    echo ""

    local script="${APP_SCRIPT[$app]}"
    local script_path="$SCRIPTS_DIR/$script"

    _export_app_env "$app"

    bash "$script_path" --subdomain 2>&1 | tee -a "$LOG_FILE"
    local result=${PIPESTATUS[0]}

    echo ""

    if [[ $result -eq 0 ]]; then
        echo_success "$app subdomain configured"
    else
        echo_error "$app subdomain configuration failed"
    fi
}

install_multi_instances() {
    local app="$1"
    local instances="${MULTI_INSTANCES[$app]:-}"

    if [[ -z "$instances" ]]; then
        return 0
    fi

    local script="${APP_SCRIPT[$app]}"
    local script_path="$SCRIPTS_DIR/$script"

    IFS=',' read -ra instance_array <<< "$instances"
    for instance in "${instance_array[@]}"; do
        instance=$(echo "$instance" | tr -d ' ')
        echo_info "Adding $app instance: $instance..."
        echo ""

        bash "$script_path" --add "$instance" 2>&1 | tee -a "$LOG_FILE"
        local result=${PIPESTATUS[0]}

        echo ""

        if [[ $result -eq 0 ]]; then
            echo_success "$app-$instance added"
        else
            echo_error "$app-$instance failed"
        fi
    done
}

# ==============================================================================
# Main Installation Runner
# ==============================================================================

run_app_installation() {
    echo_header "Installing Applications"

    # Ensure log file exists
    LOG_FILE="${LOG_FILE:-/root/logs/bootstrap.log}"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    # Install Swizzin base first
    install_swizzin_base

    # Configure panel subdomain immediately after base install (before other apps)
    if [[ " ${SUBDOMAIN_APPS[*]} " =~ " panel " ]]; then
        echo_info "Configuring panel subdomain..."
        echo ""

        local script_path="$SCRIPTS_DIR/panel.sh"
        if [[ -f "$script_path" ]]; then
            _export_app_env "panel"
            bash "$script_path" --subdomain 2>&1 | tee -a "$LOG_FILE"
            if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
                echo_success "Panel subdomain configured"
            else
                echo_error "Panel subdomain configuration failed"
            fi
            echo ""
        fi
    fi

    # Install apps in order
    for app in "${INSTALL_ORDER[@]}"; do
        # Skip if not selected
        if [[ ! " ${SELECTED_APPS[*]} " =~ " ${app} " ]]; then
            continue
        fi

        # Skip special cases
        if [[ "$app" == "emby-watchdog" ]]; then
            # Only install if emby is selected
            if [[ " ${SELECTED_APPS[*]} " =~ " emby " ]]; then
                echo_progress_start "Installing Emby watchdog"
                bash "$SCRIPTS_DIR/emby-watchdog.sh" --install >>"$LOG_FILE" 2>&1
                echo_progress_done "Emby watchdog installed"
            fi
            continue
        fi

        # Install the app
        install_app "$app"

        # Configure subdomain if requested
        install_subdomain "$app"

        # Add multi-instances if requested
        install_multi_instances "$app"
    done

    echo ""
    echo_success "All applications installed"
}

# ==============================================================================
# Global Variables
# ==============================================================================

SELECTED_APPS=()
SUBDOMAIN_APPS=()
declare -A MULTI_INSTANCES
