#!/bin/bash
set -euo pipefail
# plex-tunnel - Plex with VPN tunnel to bypass Hetzner IP bans
# STiXzoOR 2025
# Usage: bash plex-tunnel.sh [--gluetun|--wireguard] [--subdomain [--revert]|--status|--update|--remove [--force]|--migrate]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

# ==============================================================================
# Panel Helper
# ==============================================================================
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

# ==============================================================================
# Logging & Verbose Mode
# ==============================================================================
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

verbose=false
_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

# ==============================================================================
# App Configuration
# ==============================================================================
app_name="plex-tunnel"
app_pretty="Plex Tunnel"
app_lockname="plextunnel"
app_baseurl="plex"
app_port="32400"

app_dir="/opt/${app_name}"
app_configdir="${app_dir}/config"
app_servicefile="${app_name}.service"

app_icon_name="plex"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/plex.png"

# Paths
backup_dir="/opt/swizzin-extras/${app_name}-backups"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# Native Plex paths for migration
native_plex_dir="/var/lib/plexmediaserver"
native_plex_prefs="${native_plex_dir}/Library/Application Support/Plex Media Server/Preferences.xml"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# ==============================================================================
# Tunnel Mode Detection
# ==============================================================================
_get_tunnel_mode() {
    swizdb get "${app_name}/mode" 2>/dev/null || echo ""
}

_set_tunnel_mode() {
    swizdb set "${app_name}/mode" "$1"
}

# ==============================================================================
# Docker Installation
# ==============================================================================
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_progress_start "Installing Docker"

    apt_install ca-certificates curl gnupg

    . /etc/os-release

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$log" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update >>"$log" 2>&1

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }

    systemctl enable --now docker >>"$log" 2>&1

    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_progress_done "Docker installed"
}

# ==============================================================================
# Media Path Discovery (from Sonarr/Radarr/Lidarr/Readarr - base + multi-instance)
# ==============================================================================
_discover_media_paths() {
    MEDIA_PATHS=()
    MEDIA_MOUNT_NAMES=()
    local -A seen_paths=()

    echo_progress_start "Discovering media paths from *arr applications"

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo_info "sqlite3 not found, skipping database auto-discovery"
        echo_progress_done "Discovery complete (no sqlite3)"
    else
        # Scan for arr lock files and query their databases
        for lock in /install/.sonarr.lock /install/.sonarr_*.lock \
            /install/.radarr.lock /install/.radarr_*.lock \
            /install/.lidarr.lock /install/.lidarr_*.lock \
            /install/.readarr.lock /install/.readarr_*.lock; do
            [[ -f "$lock" ]] || continue

            local lock_basename
            lock_basename=$(basename "$lock" .lock)
            lock_basename="${lock_basename#.}"

            # Determine config directory name
            local config_dir_name db_name
            case "$lock_basename" in
                sonarr)
                    config_dir_name="Sonarr"
                    db_name="sonarr.db"
                    ;;
                radarr)
                    config_dir_name="Radarr"
                    db_name="radarr.db"
                    ;;
                lidarr)
                    config_dir_name="Lidarr"
                    db_name="lidarr.db"
                    ;;
                readarr)
                    config_dir_name="Readarr"
                    db_name="readarr.db"
                    ;;
                sonarr_*)
                    local instance="${lock_basename#sonarr_}"
                    config_dir_name="sonarr-${instance}"
                    db_name="sonarr.db"
                    ;;
                radarr_*)
                    local instance="${lock_basename#radarr_}"
                    config_dir_name="radarr-${instance}"
                    db_name="radarr.db"
                    ;;
                lidarr_*)
                    local instance="${lock_basename#lidarr_}"
                    config_dir_name="lidarr-${instance}"
                    db_name="lidarr.db"
                    ;;
                readarr_*)
                    local instance="${lock_basename#readarr_}"
                    config_dir_name="readarr-${instance}"
                    db_name="readarr.db"
                    ;;
                *) continue ;;
            esac

            # Find the database file
            for db in /home/*/.config/"${config_dir_name}"/"${db_name}" \
                /home/*/.config/"${config_dir_name}"/nzbdrone.db; do
                [[ -f "$db" ]] || continue
                while IFS= read -r path; do
                    [[ -z "$path" ]] && continue
                    path="${path%/}"
                    if [[ -z "${seen_paths[$path]+x}" ]]; then
                        seen_paths["$path"]=1
                        MEDIA_PATHS+=("$path")
                    fi
                done < <(sqlite3 "$db" "SELECT Path FROM RootFolders;" 2>/dev/null)
            done
        done
        echo_progress_done "Discovery complete"
    fi

    # Use full paths as mount names (same path inside container)
    for path in "${MEDIA_PATHS[@]}"; do
        MEDIA_MOUNT_NAMES+=("$path")
    done

    # Display discovered paths
    if [[ ${#MEDIA_PATHS[@]} -gt 0 ]]; then
        echo_info "Discovered media paths:"
        for path in "${MEDIA_PATHS[@]}"; do
            echo_info "  $path"
        done

        if ! ask "Use these paths?" Y; then
            MEDIA_PATHS=()
            MEDIA_MOUNT_NAMES=()
        fi
    else
        echo_info "No *arr installations found for auto-discovery"
    fi

    # Allow adding additional paths
    while true; do
        if [[ ${#MEDIA_PATHS[@]} -eq 0 ]]; then
            echo_query "Enter a media path (e.g., /mnt/media/movies, or leave empty to cancel)" ""
        else
            if ! ask "Add another media path?" N; then
                break
            fi
            echo_query "Enter the media path (or leave empty to skip)" ""
        fi

        local new_path
        read -r new_path </dev/tty
        if [[ -z "$new_path" ]]; then
            [[ ${#MEDIA_PATHS[@]} -gt 0 ]] && break
            echo_info "No path entered"
            continue
        fi

        new_path="${new_path%/}"

        if [[ -n "${seen_paths[$new_path]+x}" ]]; then
            echo_info "Path already added, skipping"
            continue
        fi

        seen_paths["$new_path"]=1
        MEDIA_PATHS+=("$new_path")
        MEDIA_MOUNT_NAMES+=("$new_path")

        echo_info "Added: $new_path"
    done

    if [[ ${#MEDIA_PATHS[@]} -eq 0 ]]; then
        echo_error "At least one media path is required"
        exit 1
    fi
}

# ==============================================================================
# Gluetun VPN Configuration
# ==============================================================================
_prompt_gluetun_config() {
    # Provider selection
    if [[ -z "${VPN_PROVIDER:-}" ]]; then
        echo_info "Supported VPN providers: nordvpn, surfshark, protonvpn, mullvad, pia, expressvpn, ivpn, windscribe"
        echo_query "Enter VPN provider" ""
        read -r VPN_PROVIDER </dev/tty
        if [[ -z "$VPN_PROVIDER" ]]; then
            echo_error "VPN provider is required"
            exit 1
        fi
    fi
    VPN_PROVIDER="${VPN_PROVIDER,,}" # lowercase

    # VPN type selection
    if [[ -z "${VPN_TYPE:-}" ]]; then
        if ask "Use WireGuard? (faster, recommended)" Y; then
            VPN_TYPE="wireguard"
        else
            VPN_TYPE="openvpn"
        fi
    fi

    echo_info "VPN Provider: $VPN_PROVIDER"
    echo_info "VPN Type: $VPN_TYPE"

    # Provider-specific prompts
    case "$VPN_PROVIDER" in
        nordvpn | surfshark)
            if [[ "$VPN_TYPE" == "wireguard" ]]; then
                if [[ -z "${WIREGUARD_PRIVATE_KEY:-}" ]]; then
                    echo_query "Enter WireGuard private key (from provider dashboard)" ""
                    read -r WIREGUARD_PRIVATE_KEY </dev/tty
                    [[ -z "$WIREGUARD_PRIVATE_KEY" ]] && {
                        echo_error "WireGuard private key required"
                        exit 1
                    }
                fi
            else
                if [[ -z "${OPENVPN_USER:-}" ]]; then
                    echo_query "Enter OpenVPN username" ""
                    read -r OPENVPN_USER </dev/tty
                    [[ -z "$OPENVPN_USER" ]] && {
                        echo_error "OpenVPN username required"
                        exit 1
                    }
                fi
                if [[ -z "${OPENVPN_PASSWORD:-}" ]]; then
                    echo_query "Enter OpenVPN password" ""
                    read -rs OPENVPN_PASSWORD </dev/tty
                    echo
                    [[ -z "$OPENVPN_PASSWORD" ]] && {
                        echo_error "OpenVPN password required"
                        exit 1
                    }
                fi
            fi
            ;;
        protonvpn)
            if [[ "$VPN_TYPE" == "wireguard" ]]; then
                if [[ -z "${WIREGUARD_PRIVATE_KEY:-}" ]]; then
                    echo_query "Enter WireGuard private key" ""
                    read -r WIREGUARD_PRIVATE_KEY </dev/tty
                    [[ -z "$WIREGUARD_PRIVATE_KEY" ]] && {
                        echo_error "WireGuard private key required"
                        exit 1
                    }
                fi
            else
                if [[ -z "${OPENVPN_USER:-}" ]]; then
                    echo_query "Enter OpenVPN username (OpenVPN/IKEv2 username from account)" ""
                    read -r OPENVPN_USER </dev/tty
                    [[ -z "$OPENVPN_USER" ]] && {
                        echo_error "OpenVPN username required"
                        exit 1
                    }
                fi
                if [[ -z "${OPENVPN_PASSWORD:-}" ]]; then
                    echo_query "Enter OpenVPN password" ""
                    read -rs OPENVPN_PASSWORD </dev/tty
                    echo
                    [[ -z "$OPENVPN_PASSWORD" ]] && {
                        echo_error "OpenVPN password required"
                        exit 1
                    }
                fi
            fi
            ;;
        mullvad)
            if [[ "$VPN_TYPE" == "wireguard" ]]; then
                if [[ -z "${WIREGUARD_PRIVATE_KEY:-}" ]]; then
                    echo_query "Enter WireGuard private key" ""
                    read -r WIREGUARD_PRIVATE_KEY </dev/tty
                    [[ -z "$WIREGUARD_PRIVATE_KEY" ]] && {
                        echo_error "WireGuard private key required"
                        exit 1
                    }
                fi
                if [[ -z "${WIREGUARD_ADDRESSES:-}" ]]; then
                    echo_query "Enter WireGuard address (e.g., 10.x.x.x/32)" ""
                    read -r WIREGUARD_ADDRESSES </dev/tty
                    [[ -z "$WIREGUARD_ADDRESSES" ]] && {
                        echo_error "WireGuard address required"
                        exit 1
                    }
                fi
            else
                if [[ -z "${OPENVPN_USER:-}" ]]; then
                    echo_query "Enter Mullvad account number" ""
                    read -r OPENVPN_USER </dev/tty
                    [[ -z "$OPENVPN_USER" ]] && {
                        echo_error "Account number required"
                        exit 1
                    }
                fi
                OPENVPN_PASSWORD="m" # Mullvad uses 'm' as password
            fi
            ;;
        pia)
            if [[ -z "${OPENVPN_USER:-}" ]]; then
                echo_query "Enter PIA username" ""
                read -r OPENVPN_USER </dev/tty
                [[ -z "$OPENVPN_USER" ]] && {
                    echo_error "Username required"
                    exit 1
                }
            fi
            if [[ -z "${OPENVPN_PASSWORD:-}" ]]; then
                echo_query "Enter PIA password" ""
                read -rs OPENVPN_PASSWORD </dev/tty
                echo
                [[ -z "$OPENVPN_PASSWORD" ]] && {
                    echo_error "Password required"
                    exit 1
                }
            fi
            ;;
        *)
            # Generic provider - prompt for credentials
            if [[ "$VPN_TYPE" == "wireguard" ]]; then
                if [[ -z "${WIREGUARD_PRIVATE_KEY:-}" ]]; then
                    echo_query "Enter WireGuard private key" ""
                    read -r WIREGUARD_PRIVATE_KEY </dev/tty
                    [[ -z "$WIREGUARD_PRIVATE_KEY" ]] && {
                        echo_error "WireGuard private key required"
                        exit 1
                    }
                fi
            else
                if [[ -z "${OPENVPN_USER:-}" ]]; then
                    echo_query "Enter OpenVPN username" ""
                    read -r OPENVPN_USER </dev/tty
                fi
                if [[ -z "${OPENVPN_PASSWORD:-}" ]]; then
                    echo_query "Enter OpenVPN password" ""
                    read -rs OPENVPN_PASSWORD </dev/tty
                    echo
                fi
            fi
            ;;
    esac

    # Optional server country
    if [[ -z "${SERVER_COUNTRIES:-}" ]]; then
        echo_query "Enter server country (optional, e.g., Netherlands, leave empty for any)" ""
        read -r SERVER_COUNTRIES </dev/tty
    fi
}

# ==============================================================================
# WireGuard Relay Configuration
# ==============================================================================
_prompt_wireguard_config() {
    echo_info "WireGuard relay mode requires a VPS with WireGuard server configured"
    echo_info "Run plex-tunnel-vps.sh on your VPS to set up the server side"
    echo ""

    if [[ -z "${WG_RELAY_ENDPOINT:-}" ]]; then
        echo_query "Enter WireGuard endpoint (e.g., vps.example.com:51820)" ""
        read -r WG_RELAY_ENDPOINT </dev/tty
        [[ -z "$WG_RELAY_ENDPOINT" ]] && {
            echo_error "Endpoint required"
            exit 1
        }
    fi

    if [[ -z "${WG_RELAY_PUBKEY:-}" ]]; then
        echo_query "Enter server public key" ""
        read -r WG_RELAY_PUBKEY </dev/tty
        [[ -z "$WG_RELAY_PUBKEY" ]] && {
            echo_error "Server public key required"
            exit 1
        }
    fi

    if [[ -z "${WG_RELAY_PRIVKEY:-}" ]]; then
        echo_query "Enter client private key" ""
        read -r WG_RELAY_PRIVKEY </dev/tty
        [[ -z "$WG_RELAY_PRIVKEY" ]] && {
            echo_error "Client private key required"
            exit 1
        }
    fi

    if [[ -z "${WG_RELAY_ADDRESS:-}" ]]; then
        echo_query "Enter client address (e.g., 10.13.13.2/24)" ""
        read -r WG_RELAY_ADDRESS </dev/tty
        [[ -z "$WG_RELAY_ADDRESS" ]] && {
            echo_error "Client address required"
            exit 1
        }
    fi

    if [[ -z "${WG_RELAY_PRESHARED:-}" ]]; then
        echo_query "Enter preshared key (optional, leave empty to skip)" ""
        read -r WG_RELAY_PRESHARED </dev/tty
    fi
}

# ==============================================================================
# Plex Claim Token
# ==============================================================================
_prompt_plex_claim() {
    if [[ -z "${PLEX_CLAIM:-}" ]]; then
        echo_info "Get a claim token from: https://www.plex.tv/claim/"
        echo_query "Enter Plex claim token (optional for initial setup, required for linking)" ""
        read -r PLEX_CLAIM </dev/tty
    fi
}

# ==============================================================================
# Docker Compose Generation - Gluetun Mode
# ==============================================================================
_generate_gluetun_compose() {
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")
    local tz="${TZ:-$(cat /etc/timezone 2>/dev/null || echo 'UTC')}"

    echo_progress_start "Generating Gluetun Docker Compose configuration"

    mkdir -p "${app_dir}/gluetun"
    chown -R "${user}:${user}" "$app_dir"

    {
        cat <<COMPOSE
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: ${app_name}-gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "${app_port}:32400"
    environment:
      - VPN_SERVICE_PROVIDER=${VPN_PROVIDER}
      - VPN_TYPE=${VPN_TYPE}
COMPOSE

        # Provider-specific environment variables
        if [[ "$VPN_TYPE" == "wireguard" ]]; then
            echo "      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}"
            [[ -n "${WIREGUARD_ADDRESSES:-}" ]] && echo "      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES}"
        else
            [[ -n "${OPENVPN_USER:-}" ]] && echo "      - OPENVPN_USER=${OPENVPN_USER}"
            [[ -n "${OPENVPN_PASSWORD:-}" ]] && echo "      - OPENVPN_PASSWORD=${OPENVPN_PASSWORD}"
        fi

        [[ -n "${SERVER_COUNTRIES:-}" ]] && echo "      - SERVER_COUNTRIES=${SERVER_COUNTRIES}"

        cat <<COMPOSE
    volumes:
      - ${app_dir}/gluetun:/gluetun
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://www.google.com"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: ${app_name}
    network_mode: "service:gluetun"
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - TZ=${tz}
      - VERSION=docker
COMPOSE

        [[ -n "${PLEX_CLAIM:-}" ]] && echo "      - PLEX_CLAIM=${PLEX_CLAIM}"

        echo "    volumes:"
        echo "      - ${app_configdir}:/config"

        # Media volumes
        for i in "${!MEDIA_PATHS[@]}"; do
            echo "      - ${MEDIA_PATHS[$i]}:${MEDIA_MOUNT_NAMES[$i]}"
        done

        cat <<COMPOSE
    depends_on:
      gluetun:
        condition: service_healthy
    restart: unless-stopped
COMPOSE
    } >"${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"
}

# ==============================================================================
# Docker Compose Generation - WireGuard Mode
# ==============================================================================
_generate_wireguard_compose() {
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")
    local tz="${TZ:-$(cat /etc/timezone 2>/dev/null || echo 'UTC')}"

    echo_progress_start "Generating WireGuard Docker Compose configuration"

    mkdir -p "${app_dir}/wireguard"
    chown -R "${user}:${user}" "$app_dir"

    # Generate wg0.conf
    {
        cat <<WGCONF
[Interface]
Address = ${WG_RELAY_ADDRESS}
PrivateKey = ${WG_RELAY_PRIVKEY}
DNS = 9.9.9.9

PostUp = iptables -t nat -A POSTROUTING -o wg+ -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg+ -j MASQUERADE

[Peer]
PublicKey = ${WG_RELAY_PUBKEY}
WGCONF
        [[ -n "${WG_RELAY_PRESHARED:-}" ]] && echo "PresharedKey = ${WG_RELAY_PRESHARED}"
        cat <<WGCONF
Endpoint = ${WG_RELAY_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGCONF
    } >"${app_dir}/wireguard/wg0.conf"
    chmod 600 "${app_dir}/wireguard/wg0.conf"

    # Generate docker-compose.yml
    {
        cat <<COMPOSE
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: ${app_name}-wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - TZ=${tz}
    ports:
      - "${app_port}:32400"
    volumes:
      - ${app_dir}/wireguard:/config
      - /lib/modules:/lib/modules:ro
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "ping", "-c", "1", "8.8.8.8"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: ${app_name}
    network_mode: "service:wireguard"
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - TZ=${tz}
      - VERSION=docker
COMPOSE

        [[ -n "${PLEX_CLAIM:-}" ]] && echo "      - PLEX_CLAIM=${PLEX_CLAIM}"

        echo "    volumes:"
        echo "      - ${app_configdir}:/config"

        for i in "${!MEDIA_PATHS[@]}"; do
            echo "      - ${MEDIA_PATHS[$i]}:${MEDIA_MOUNT_NAMES[$i]}"
        done

        cat <<COMPOSE
    depends_on:
      wireguard:
        condition: service_healthy
    restart: unless-stopped
COMPOSE
    } >"${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"
}

# ==============================================================================
# Container Management
# ==============================================================================
_start_containers() {
    echo_progress_start "Pulling Docker images"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker images"
        exit 1
    }
    echo_progress_done "Docker images pulled"

    echo_progress_start "Starting containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "Containers started"
}

# ==============================================================================
# Systemd Service
# ==============================================================================
_systemd_service() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Plex with VPN Tunnel)
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=180
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Domain / LE / Organizr Helpers
# ==============================================================================
_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "${app_name}/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${PLEX_TUNNEL_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "$PLEX_TUNNEL_DOMAIN" ]; then
        echo_info "Using domain from PLEX_TUNNEL_DOMAIN: $PLEX_TUNNEL_DOMAIN"
        app_domain="$PLEX_TUNNEL_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for Plex" "[$existing_domain]"
    else
        echo_query "Enter domain for Plex" "(e.g., plex.example.com)"
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
    export PLEX_TUNNEL_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "$PLEX_TUNNEL_LE_INTERACTIVE" ]; then
        echo_info "Using LE mode from PLEX_TUNNEL_LE_INTERACTIVE: $PLEX_TUNNEL_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export PLEX_TUNNEL_LE_INTERACTIVE="yes"
    else
        export PLEX_TUNNEL_LE_INTERACTIVE="no"
    fi
}

_request_certificate() {
    local domain="$1"
    local le_hostname="${PLEX_TUNNEL_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${PLEX_TUNNEL_LE_INTERACTIVE:-no}"

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
        echo_error "Check $log for details"
        exit 1
    fi

    echo_info "Let's Encrypt certificate issued for $le_hostname"
}

_get_organizr_domain() {
    if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
        grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
    fi
}

_exclude_from_organizr() {
    local modified=false
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"

    if [ -f "$organizr_config" ] && grep -q "^${app_name}:" "$organizr_config"; then
        echo_progress_start "Removing ${app_pretty} from Organizr protected apps"
        sed -i "/^${app_name}:/d" "$organizr_config"
        modified=true
    fi

    if [ -f "$apps_include" ] && grep -q "include /etc/nginx/apps/${app_name}.conf;" "$apps_include"; then
        sed -i "\|include /etc/nginx/apps/${app_name}.conf;|d" "$apps_include"
        modified=true
    fi

    if [ "$modified" = true ]; then
        echo_progress_done "Removed from Organizr"
    fi
}

# ==============================================================================
# Subdomain Vhost Creation
# ==============================================================================
_create_subdomain_vhost() {
    local domain="$1"
    local le_hostname="${2:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local organizr_domain
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

    client_max_body_size 0;
    proxy_redirect off;
    proxy_buffering off;

    # Streaming timeouts (1 hour for long-running streams)
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    ${csp_header}

    location / {
        include snippets/proxy.conf;
        proxy_pass http://127.0.0.1:${app_port}/;

        # WebSocket support for Plex Together, sync notifications
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header X-Plex-Client-Identifier \$http_x_plex_client_identifier;
        proxy_set_header X-Plex-Device \$http_x_plex_device;
        proxy_set_header X-Plex-Device-Name \$http_x_plex_device_name;
        proxy_set_header X-Plex-Platform \$http_x_plex_platform;
        proxy_set_header X-Plex-Platform-Version \$http_x_plex_platform_version;
        proxy_set_header X-Plex-Product \$http_x_plex_product;
        proxy_set_header X-Plex-Token \$http_x_plex_token;
        proxy_set_header X-Plex-Version \$http_x_plex_version;
        proxy_set_header X-Plex-Nocache \$http_x_plex_nocache;
        proxy_set_header X-Plex-Provides \$http_x_plex_provides;
        proxy_set_header X-Plex-Device-Vendor \$http_x_plex_device_vendor;
        proxy_set_header X-Plex-Model \$http_x_plex_model;
    }

    location /library/streams/ {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
VHOST

    [ -L "$subdomain_enabled" ] || ln -s "$subdomain_vhost" "$subdomain_enabled"

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

    # Remove existing class if present
    sed -i "/^class ${app_lockname}_meta:/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

    cat >>"$profiles_py" <<PYTHON

class ${app_lockname}_meta:
    name = "${app_name}"
    pretty_name = "${app_pretty}"
    urloverride = "https://${domain}"
    systemd = "${app_name}"
    img = "${app_icon_name}"
    check_theD = True
PYTHON

    echo_progress_done "Panel meta updated"
}

_remove_panel_meta() {
    if [ -f "$profiles_py" ]; then
        echo_progress_start "Removing panel meta"
        sed -i "/^class ${app_lockname}_meta:/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
        echo_progress_done "Panel meta removed"
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
# Migration from Native Plex
# ==============================================================================
_detect_native_plex() {
    [[ -d "$native_plex_dir" ]] && [[ -f "/install/.plex.lock" ]]
}

_migrate_from_native() {
    if ! _detect_native_plex; then
        echo_info "No native Plex installation detected"
        return 0
    fi

    echo_warn "Native Plex installation detected at $native_plex_dir"
    if ! ask "Would you like to migrate the existing Plex configuration to the containerized version?" Y; then
        echo_info "Skipping migration. Starting fresh."
        return 0
    fi

    echo_progress_start "Migrating native Plex configuration"

    # Stop native Plex
    systemctl stop plexmediaserver 2>/dev/null || true

    # Create backup
    mkdir -p "$backup_dir"
    if [[ -f "$native_plex_prefs" ]]; then
        cp "$native_plex_prefs" "$backup_dir/Preferences.xml.bak"
        echo_info "Backed up Preferences.xml"
    fi

    # Copy config to container volume
    mkdir -p "$app_configdir"
    local native_lib="${native_plex_dir}/Library/Application Support/Plex Media Server"

    if [[ -d "$native_lib" ]]; then
        # Copy key configuration files
        for item in "Preferences.xml" "Plug-in Support" "Metadata" "Media" "Plug-ins"; do
            if [[ -e "${native_lib}/${item}" ]]; then
                echo_info "Copying ${item}..."
                cp -a "${native_lib}/${item}" "${app_configdir}/Library/Application Support/Plex Media Server/" 2>/dev/null || true
            fi
        done
    fi

    chown -R "${user}:${user}" "$app_configdir"

    # Disable native Plex service (don't remove in case user wants to revert)
    systemctl disable plexmediaserver 2>/dev/null || true

    echo_progress_done "Migration complete"
    echo_info "Native Plex service disabled. Remove manually if migration is successful: box remove plex"
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
# Status Command
# ==============================================================================
_status() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    local mode
    mode=$(_get_tunnel_mode)
    echo_info "Tunnel mode: ${mode:-unknown}"

    echo ""
    echo_info "Container status:"
    docker compose -f "${app_dir}/docker-compose.yml" ps 2>/dev/null || echo "  Unable to get container status"

    echo ""
    echo_info "Checking tunnel connectivity..."
    local tunnel_container="${app_name}-gluetun"
    [[ "$mode" == "wireguard" ]] && tunnel_container="${app_name}-wireguard"

    local external_ip
    external_ip=$(docker exec "$tunnel_container" wget -qO- ifconfig.me 2>/dev/null || echo "Unable to determine")
    echo_info "External IP (via tunnel): $external_ip"

    echo ""
    echo_info "Plex server status:"
    if curl -sf --max-time 5 "http://127.0.0.1:${app_port}/identity" >/dev/null 2>&1; then
        echo_info "  Plex is responding on port ${app_port}"
    else
        echo_warn "  Plex is not responding (may still be starting)"
    fi

    exit 0
}

# ==============================================================================
# Update Command
# ==============================================================================
_update() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Pulling latest images"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest images"
        exit 1
    }
    echo_progress_done "Latest images pulled"

    echo_progress_start "Recreating containers"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"

    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove Command
# ==============================================================================
_remove() {
    local force="$1"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove containers
    echo_progress_start "Stopping containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

    # Remove Docker images
    echo_progress_start "Removing Docker images"
    docker rmi qmcgaw/gluetun lscr.io/linuxserver/plex lscr.io/linuxserver/wireguard >>"$log" 2>&1 || true
    echo_progress_done "Docker images removed"

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove subdomain vhost if exists
    if [ -f "$subdomain_vhost" ] || [ -L "$subdomain_enabled" ]; then
        echo_progress_start "Removing subdomain nginx configuration"
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Subdomain configuration removed"
    fi

    # Remove panel meta
    _remove_panel_meta

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Remove backup dir
    rm -rf "$backup_dir"

    # Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/mode" 2>/dev/null || true
        swizdb clear "${app_name}/domain" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_configdir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Install - Gluetun Mode
# ==============================================================================
_install_gluetun() {
    if [[ -f "/install/.${app_lockname}.lock" ]]; then
        echo_info "${app_pretty} already installed"
        echo_info "Use --remove first to reinstall, or --update to update"
        exit 0
    fi

    echo_info "Installing ${app_pretty} with Gluetun VPN tunnel..."

    # Set owner
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _prompt_gluetun_config
    _prompt_plex_claim
    _discover_media_paths
    _migrate_from_native

    mkdir -p "$app_configdir"
    chown -R "${user}:${user}" "$app_dir"

    _generate_gluetun_compose
    _start_containers
    _systemd_service

    _set_tunnel_mode "gluetun"

    touch "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} installed with Gluetun"
    echo_info "Access Plex at: http://your-server:${app_port}/web"
    echo_info "Check tunnel status with: bash plex-tunnel.sh --status"
}

# ==============================================================================
# Install - WireGuard Mode
# ==============================================================================
_install_wireguard() {
    if [[ -f "/install/.${app_lockname}.lock" ]]; then
        echo_info "${app_pretty} already installed"
        echo_info "Use --remove first to reinstall, or --update to update"
        exit 0
    fi

    echo_info "Installing ${app_pretty} with WireGuard relay tunnel..."

    # Set owner
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _prompt_wireguard_config
    _prompt_plex_claim
    _discover_media_paths
    _migrate_from_native

    mkdir -p "$app_configdir"
    chown -R "${user}:${user}" "$app_dir"

    _generate_wireguard_compose
    _start_containers
    _systemd_service

    _set_tunnel_mode "wireguard"

    touch "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} installed with WireGuard relay"
    echo_info "Access Plex at: http://your-server:${app_port}/web"
    echo_info "Check tunnel status with: bash plex-tunnel.sh --status"
}

# ==============================================================================
# Subdomain Mode
# ==============================================================================
_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${PLEX_TUNNEL_LE_HOSTNAME:-$domain}"
    local state
    state=$(_get_install_state)

    echo_info "${app_pretty} Subdomain Setup"
    echo_info "Domain: $domain"
    [ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
    echo_info "Current state: $state"

    case "$state" in
        "not_installed")
            echo_error "${app_pretty} must be installed first with --gluetun or --wireguard"
            exit 1
            ;;
        "installed")
            _request_certificate "$domain"
            _create_subdomain_vhost "$domain" "$le_hostname"
            _add_panel_meta "$domain"
            _exclude_from_organizr
            _reload_nginx
            echo_success "${app_pretty} subdomain configured"
            echo_info "Access at: https://$domain"
            ;;
        "subdomain")
            echo_info "Already in subdomain mode"
            ;;
    esac
}

_revert_subdomain() {
    echo_info "Reverting ${app_pretty} subdomain configuration..."

    [ -L "$subdomain_enabled" ] && rm -f "$subdomain_enabled"
    [ -f "$subdomain_vhost" ] && rm -f "$subdomain_vhost"

    _remove_panel_meta

    _reload_nginx 2>/dev/null || true

    echo_success "${app_pretty} subdomain removed"
    echo_info "Access at: http://your-server:${app_port}/web"
}

# ==============================================================================
# Usage
# ==============================================================================
_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install Plex with a VPN tunnel to bypass Hetzner IP bans.

INSTALLATION:
  --gluetun           Install with Gluetun VPN (NordVPN, Surfshark, ProtonVPN, etc.)
  --wireguard         Install with WireGuard relay to external VPS

SUBDOMAIN:
  --subdomain         Configure nginx subdomain with SSL
  --subdomain --revert Remove subdomain configuration

MANAGEMENT:
  --status            Show tunnel and container status
  --update [--verbose] Pull latest images and recreate containers
  --remove [--force]  Complete removal
  --migrate           Migrate from native Plex installation

ENVIRONMENT VARIABLES (Gluetun mode):
  VPN_PROVIDER        VPN provider (nordvpn, surfshark, protonvpn, mullvad, pia, etc.)
  VPN_TYPE            wireguard or openvpn
  WIREGUARD_PRIVATE_KEY  WireGuard private key
  WIREGUARD_ADDRESSES    WireGuard address (for some providers)
  OPENVPN_USER        OpenVPN username
  OPENVPN_PASSWORD    OpenVPN password
  SERVER_COUNTRIES    Optional server country filter

ENVIRONMENT VARIABLES (WireGuard relay mode):
  WG_RELAY_ENDPOINT   VPS endpoint (e.g., vps.example.com:51820)
  WG_RELAY_PUBKEY     Server public key
  WG_RELAY_PRIVKEY    Client private key
  WG_RELAY_ADDRESS    Client address (e.g., 10.13.13.2/24)
  WG_RELAY_PRESHARED  Optional preshared key

COMMON VARIABLES:
  PLEX_CLAIM          Plex claim token from https://plex.tv/claim
  PLEX_TUNNEL_DOMAIN  Domain for subdomain mode
  TZ                  Timezone (default: from /etc/timezone)

EXAMPLES:
  # Install with Mullvad VPN
  VPN_PROVIDER=mullvad WIREGUARD_PRIVATE_KEY=xxx WIREGUARD_ADDRESSES=10.x.x.x/32 \\
    bash plex-tunnel.sh --gluetun

  # Install with WireGuard relay to VPS
  WG_RELAY_ENDPOINT=vps.example.com:51820 WG_RELAY_PUBKEY=xxx \\
    WG_RELAY_PRIVKEY=xxx WG_RELAY_ADDRESS=10.13.13.2/24 \\
    bash plex-tunnel.sh --wireguard

  # Add subdomain
  PLEX_TUNNEL_DOMAIN=plex.example.com bash plex-tunnel.sh --subdomain

EOF
    exit 1
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

case "${1:-}" in
    "--gluetun")
        _install_gluetun
        ;;
    "--wireguard")
        _install_wireguard
        ;;
    "--subdomain")
        case "${2:-}" in
            "--revert") _revert_subdomain ;;
            "") _install_subdomain ;;
            *) _usage ;;
        esac
        ;;
    "--status")
        _status
        ;;
    "--update")
        _update
        ;;
    "--remove")
        _remove "$2"
        ;;
    "--migrate")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} must be installed first"
            exit 1
        fi
        _migrate_from_native
        ;;
    "")
        _usage
        ;;
    *)
        _usage
        ;;
esac
