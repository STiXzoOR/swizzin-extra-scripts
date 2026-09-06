#!/bin/bash
set -euo pipefail
# mediafusion installer
# STiXzoOR 2026
# Usage: bash mediafusion.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

# shellcheck source=lib/debrid-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/debrid-utils.sh" 2>/dev/null || true

# shellcheck source=lib/prowlarr-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/prowlarr-utils.sh" 2>/dev/null || true

# ==============================================================================
# Panel Helper - Download and cache for panel integration
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
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
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

# ==============================================================================
# App Configuration
# ==============================================================================

app_name="mediafusion"
app_pretty="MediaFusion"
app_lockname="${app_name}"
app_baseurl="${app_name}"

app_dir="/opt/mediafusion"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://raw.githubusercontent.com/mhdzumair/MediaFusion/228f4946b4a89425c129fede7ac1d93bc69b46fa/resources/images/mediafusion_logo.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# ==============================================================================
# Port Allocation (4 dynamic ports)
# ==============================================================================
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

if _existing_pg_port="$(swizdb get "${app_name}/pg_port" 2>/dev/null)" && [[ -n "$_existing_pg_port" ]]; then
    pg_port="$_existing_pg_port"
else
    pg_port=$(port 10000 12000)
fi

if _existing_redis_port="$(swizdb get "${app_name}/redis_port" 2>/dev/null)" && [[ -n "$_existing_redis_port" ]]; then
    redis_port="$_existing_redis_port"
else
    redis_port=$(port 10000 12000)
fi

if _existing_trawl_port="$(swizdb get "${app_name}/trawl_port" 2>/dev/null)" && [[ -n "$_existing_trawl_port" ]]; then
    trawl_port="$_existing_trawl_port"
elif _existing_browser_port="$(swizdb get "${app_name}/browser_port" 2>/dev/null)" && [[ -n "$_existing_browser_port" ]]; then
    # pre-v6 installs allocated this for browserless; TRAWL reuses the port
    trawl_port="$_existing_browser_port"
else
    trawl_port=$(port 10000 12000)
fi

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

    # Source os-release once for distro detection
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

    # Use apt-get directly instead of apt_install — Docker's post-install
    # triggers service restarts that Swizzin's apt_install treats as errors
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }

    systemctl enable --now docker >>"$log" 2>&1

    # Verify Docker is running
    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_progress_done "Docker installed"
}

# ==============================================================================
# Pre-install RAM Check
# ==============================================================================
_check_ram() {
    local total_mem_mb
    total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if (( total_mem_mb < 3072 )); then
        echo_warn "System has ${total_mem_mb}MB RAM. MediaFusion recommends 4GB+"
        if ! ask "Continue anyway?" N; then
            exit 0
        fi
    fi
}

# ==============================================================================
# App Installation (5-container compose)
# ==============================================================================
_install_mediafusion() {
    mkdir -p "${app_dir}/pgdata" "${app_dir}/redis"

    # Generate credentials
    local secret_key api_password db_pass server_hostname
    secret_key=$(openssl rand -hex 16)
    api_password=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c -16)
    db_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c -32)

    # Detect server hostname: Organizr domain > nginx server_name > hostname -f
    local organizr_config="/opt/swizzin-extras/organizr-auth.conf"
    if [[ -f "$organizr_config" ]] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
        server_hostname=$(grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2)
    elif [[ -f /etc/nginx/sites-enabled/default ]]; then
        server_hostname=$(grep -m1 'server_name' /etc/nginx/sites-enabled/default | awk '{print $2}' | tr -d ';')
    else
        server_hostname=$(hostname -f)
    fi

    # Persist ports in swizdb
    swizdb set "${app_name}/port" "$app_port"
    swizdb set "${app_name}/pg_port" "$pg_port"
    swizdb set "${app_name}/redis_port" "$redis_port"
    swizdb set "${app_name}/trawl_port" "$trawl_port"

    # ==========================================================================
    # Auto-detect local services (Prowlarr, Jackett, Zilean)
    # ==========================================================================
    local prowlarr_env="" jackett_env="" zilean_env=""
    local detected_prowlarr=false detected_jackett=false detected_zilean=false

    if [[ -f /install/.prowlarr.lock ]]; then
        local pr_port pr_apikey pr_baseurl
        for cfg in /home/*/.config/Prowlarr/config.xml; do
            [[ -f "$cfg" ]] || continue
            pr_port=$(grep -oP '(?<=<Port>)\d+' "$cfg" 2>/dev/null)
            pr_apikey=$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" 2>/dev/null)
            pr_baseurl=$(grep -oP '(?<=<UrlBase>)[^<]+' "$cfg" 2>/dev/null)
            break
        done
        if [[ -n "$pr_port" && -n "$pr_apikey" ]]; then
            prowlarr_env="      PROWLARR_URL: \"http://127.0.0.1:${pr_port}${pr_baseurl:-}\"
      PROWLARR_API_KEY: \"${pr_apikey}\""
            detected_prowlarr=true
            echo_info "Detected Prowlarr on port ${pr_port}"
        fi
    fi

    if [[ -f /install/.jackett.lock ]]; then
        local jk_port jk_apikey jk_baseurl
        for cfg in /home/*/.config/Jackett/ServerConfig.json; do
            [[ -f "$cfg" ]] || continue
            jk_port=$(python3 -c "import json; print(json.load(open('$cfg'))['Port'])" 2>/dev/null)
            jk_apikey=$(python3 -c "import json; print(json.load(open('$cfg'))['APIKey'])" 2>/dev/null)
            jk_baseurl=$(python3 -c "import json; print(json.load(open('$cfg')).get('BasePathOverride', '/jackett'))" 2>/dev/null)
            break
        done
        if [[ -n "$jk_port" && -n "$jk_apikey" ]]; then
            jackett_env="      JACKETT_URL: \"http://127.0.0.1:${jk_port}${jk_baseurl:-}\"
      JACKETT_API_KEY: \"${jk_apikey}\""
            detected_jackett=true
            echo_info "Detected Jackett on port ${jk_port}"
        fi
    fi

    if [[ -f /install/.zilean.lock ]]; then
        local zl_port
        zl_port=$(swizdb get "zilean/port" 2>/dev/null) || true
        if [[ -z "$zl_port" ]]; then
            # Fallback: parse healthcheck URL which contains the actual app port
            zl_port=$(grep -oP 'http://127\.0\.0\.1:\K\d+' /opt/zilean/docker-compose.yml 2>/dev/null | head -1)
        fi
        if [[ -n "$zl_port" ]]; then
            zilean_env="      ZILEAN_URL: \"http://127.0.0.1:${zl_port}\""
            detected_zilean=true
            echo_info "Detected Zilean on port ${zl_port}"
        fi
    fi

    # ==========================================================================
    # Interactive: Scraper/Indexer Selection
    # ==========================================================================
    # Env var override for unattended install: MEDIAFUSION_SCRAPERS="prowlarr,zilean,public,dmm"
    local scrap_prowlarr="False" scrap_jackett="False" scrap_zilean="False"
    local scrap_torrentio="False" scrap_public="True" scrap_dmm="False"

    if [[ -n "${MEDIAFUSION_SCRAPERS:-}" ]]; then
        # Unattended: parse comma-separated list
        scrap_public="False"
        IFS=',' read -ra _scrapers <<< "$MEDIAFUSION_SCRAPERS"
        for s in "${_scrapers[@]}"; do
            case "${s,,}" in
                prowlarr)  scrap_prowlarr="True" ;;
                jackett)   scrap_jackett="True" ;;
                zilean)    scrap_zilean="True" ;;
                torrentio) scrap_torrentio="True" ;;
                public|public_indexers) scrap_public="True" ;;
                dmm|dmm_hashlist)      scrap_dmm="True" ;;
            esac
        done
    else
        echo ""
        echo_info "Configure scrapers/indexers for MediaFusion"
        echo_info "Detected services are pre-selected. Press Enter to accept defaults."
        echo ""

        # Auto-enable detected local services by default
        if [[ "$detected_prowlarr" == "true" ]]; then
            if ask "Enable Prowlarr scraper? (detected locally)" Y; then
                scrap_prowlarr="True"
            fi
        else
            if ask "Enable Prowlarr scraper?" N; then
                scrap_prowlarr="True"
            fi
        fi

        if [[ "$detected_jackett" == "true" ]]; then
            if ask "Enable Jackett scraper? (detected locally)" Y; then
                scrap_jackett="True"
            fi
        else
            if ask "Enable Jackett scraper?" N; then
                scrap_jackett="True"
            fi
        fi

        if [[ "$detected_zilean" == "true" ]]; then
            if ask "Enable Zilean scraper? (detected locally)" Y; then
                scrap_zilean="True"
            fi
        else
            if ask "Enable Zilean scraper?" N; then
                scrap_zilean="True"
            fi
        fi

        if ask "Enable Torrentio scraper? (external, public tracker)" N; then
            scrap_torrentio="True"
        fi

        if ask "Enable built-in public indexers (1337x, TPB, YTS, ...)?" Y; then
            scrap_public="True"
        else
            scrap_public="False"
        fi

        if ask "Enable DMM hashlist ingestion?" N; then
            scrap_dmm="True"
        fi
    fi

    # ==========================================================================
    # Interactive: Streaming Provider Selection
    # ==========================================================================
    # All providers enabled by default; user can disable ones they don't use.
    # Env var override: MEDIAFUSION_DISABLED_PROVIDERS="p2p,pikpak"
    local disabled_providers_env=""

    if [[ -n "${MEDIAFUSION_DISABLED_PROVIDERS:-}" ]]; then
        disabled_providers_env="      disabled_providers: \"[${MEDIAFUSION_DISABLED_PROVIDERS}]\""
    else
        echo ""
        echo_info "Configure streaming providers (debrid services)"
        echo_info "All providers are enabled by default. Disable any you don't use."
        echo ""

        local _disabled=()
        if ! ask "Enable Real-Debrid?" Y; then _disabled+=("realdebrid"); fi
        if ! ask "Enable AllDebrid?" Y; then _disabled+=("alldebrid"); fi
        if ! ask "Enable Premiumize?" Y; then _disabled+=("premiumize"); fi
        if ! ask "Enable Debrid-Link?" Y; then _disabled+=("debridlink"); fi
        if ! ask "Enable TorBox?" Y; then _disabled+=("torbox"); fi
        if ! ask "Enable PikPak?" N; then _disabled+=("pikpak"); fi
        if ! ask "Enable P2P (direct torrents)?" N; then _disabled+=("p2p"); fi

        if [[ ${#_disabled[@]} -gt 0 ]]; then
            local _joined
            _joined=$(printf ',"%s"' "${_disabled[@]}")
            _joined="[${_joined:1}]"
            disabled_providers_env="      disabled_providers: '${_joined}'"
        fi
    fi

    # Build scraper env block
    local scraper_env=""
    scraper_env+="      IS_SCRAP_FROM_PROWLARR: \"${scrap_prowlarr,,}\"
"
    scraper_env+="      IS_SCRAP_FROM_JACKETT: \"${scrap_jackett,,}\"
"
    scraper_env+="      IS_SCRAP_FROM_ZILEAN: \"${scrap_zilean,,}\"
"
    scraper_env+="      IS_SCRAP_FROM_TORRENTIO: \"${scrap_torrentio,,}\"
"
    scraper_env+="      IS_SCRAP_FROM_PUBLIC_INDEXERS: \"${scrap_public,,}\"
"
    scraper_env+="      IS_SCRAP_FROM_DMM_HASHLIST: \"${scrap_dmm,,}\""

    echo_progress_start "Generating Docker Compose configuration"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  mediafusion:
    image: mhdzumair/mediafusion:6.1.5
    container_name: mediafusion
    restart: unless-stopped
    network_mode: host
    environment:
      SECRET_KEY: "${secret_key}"
      API_PASSWORD: "${api_password}"
      STREAM_RS_PORT: "${app_port}"
      POSTGRES_URI: "postgresql://mediafusion:${db_pass}@127.0.0.1:${pg_port}/mediafusion"
      REDIS_URL: "redis://127.0.0.1:${redis_port}"
      HOST_URL: "https://${server_hostname}/mediafusion"
      POSTER_HOST_URL: "https://${server_hostname}/mediafusion"
      TRAWL_URL: "http://127.0.0.1:${trawl_port}"
${prowlarr_env:+${prowlarr_env}
}${jackett_env:+${jackett_env}
}${zilean_env:+${zilean_env}
}${scraper_env}
${disabled_providers_env:+${disabled_providers_env}
}      CONTACT_EMAIL: "admin@localhost"
    depends_on:
      mediafusion-postgres:
        condition: service_healthy
      mediafusion-redis:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-worker:
    image: mhdzumair/mediafusion:6.1.5
    container_name: mediafusion-worker
    restart: unless-stopped
    network_mode: host
    command: ["/usr/local/bin/mediafusion-worker"]
    environment:
      SECRET_KEY: "${secret_key}"
      API_PASSWORD: "${api_password}"
      POSTGRES_URI: "postgresql://mediafusion:${db_pass}@127.0.0.1:${pg_port}/mediafusion"
      REDIS_URL: "redis://127.0.0.1:${redis_port}"
      HOST_URL: "https://${server_hostname}/mediafusion"
      POSTER_HOST_URL: "https://${server_hostname}/mediafusion"
      TRAWL_URL: "http://127.0.0.1:${trawl_port}"
${prowlarr_env:+${prowlarr_env}
}${jackett_env:+${jackett_env}
}${zilean_env:+${zilean_env}
}${scraper_env}
${disabled_providers_env:+${disabled_providers_env}
}      CONTACT_EMAIL: "admin@localhost"
    depends_on:
      - mediafusion
    deploy:
      resources:
        limits:
          memory: 2G
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-postgres:
    image: postgres:18-alpine
    container_name: mediafusion-postgres
    restart: unless-stopped
    shm_size: 512m
    environment:
      POSTGRES_USER: mediafusion
      POSTGRES_PASSWORD: "${db_pass}"
      POSTGRES_DB: mediafusion
    volumes:
      - ${app_dir}/pgdata:/var/lib/postgresql/18/docker
    ports:
      - "127.0.0.1:${pg_port}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mediafusion"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true

  mediafusion-redis:
    image: redis:7-alpine
    container_name: mediafusion-redis
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - ${app_dir}/redis:/data
    ports:
      - "127.0.0.1:${redis_port}:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true

  mediafusion-trawl:
    image: ghcr.io/germondai/trawl:latest
    container_name: mediafusion-trawl
    restart: unless-stopped
    shm_size: 1gb
    environment:
      # DB 1 - MediaFusion itself uses DB 0 on this shared redis.
      - REDIS_URL=redis://mediafusion-redis:6379/1
      - BROWSER_POOL_SIZE=3
    ports:
      - "127.0.0.1:${trawl_port}:8191"
    depends_on:
      mediafusion-redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8191/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true

networks:
  mediafusion-net:
    driver: bridge
COMPOSE

    # Secure compose file (contains credentials)
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling MediaFusion Docker images (this may take a while)"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker images"
        exit 1
    }
    echo_progress_done "Docker images pulled"

    echo_progress_start "Starting MediaFusion containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "MediaFusion containers started"

    # Store api_password for post-install messaging
    _mediafusion_api_password="${api_password}"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_mediafusion() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=MediaFusion (Universal Stremio/Kodi Add-on with Torznab API)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_mediafusion() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect / /${app_baseurl}/;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Longer timeouts for scraper operations
			    proxy_read_timeout 120s;
			    proxy_send_timeout 120s;

			    # Rewrite hardcoded root-relative paths in HTML and JS
			    proxy_set_header Accept-Encoding "";
			    sub_filter_once off;
			    sub_filter_types application/javascript text/javascript;
			    sub_filter '"/api/v1' '"/${app_baseurl}/api/v1';
			    sub_filter '"/api?' '"/${app_baseurl}/api?';
			    sub_filter '"/app' '"/${app_baseurl}/app';
			    sub_filter "'/app" "'/${app_baseurl}/app";
			    sub_filter '"/static/' '"/${app_baseurl}/static/';
			    sub_filter '"/streaming_provider/' '"/${app_baseurl}/streaming_provider/';
			    sub_filter '"/poster/' '"/${app_baseurl}/poster/';
			    sub_filter '"/torznab' '"/${app_baseurl}/torznab';
			    sub_filter '"/manifest.json' '"/${app_baseurl}/manifest.json';
			    sub_filter 'href="/static/' 'href="/${app_baseurl}/static/';
			    sub_filter 'src="/app/' 'src="/${app_baseurl}/app/';
			    sub_filter 'href="/app/' 'href="/${app_baseurl}/app/';

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			# Torznab API bypass for Prowlarr
			location ^~ /${app_baseurl}/torznab {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/torznab;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}

			# Manifest endpoint bypass (Stremio needs unauthenticated access)
			location ^~ /${app_baseurl}/manifest.json {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/manifest.json;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

        _nginx_config_written="/etc/nginx/apps/${app_name}.conf"
        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} will run on port ${app_port}"
    fi
}

# ==============================================================================
# Prowlarr Auto-Configuration
# ==============================================================================
_configure_prowlarr() {
    local torznab_url="http://127.0.0.1:${app_port}/torznab"

    # Deploy custom Cardigann indexer definition (MediaFusion requires search params
    # that the Generic Torznab indexer can't provide)
    local prowlarr_custom_dir=""
    for cfg_dir in /home/*/.config/Prowlarr; do
        [[ -d "$cfg_dir" ]] || continue
        prowlarr_custom_dir="${cfg_dir}/Definitions/Custom"
        break
    done

    if [[ -n "$prowlarr_custom_dir" ]]; then
        local template="${SCRIPT_DIR}/resources/prowlarr/mediafusion.yml"
        if [[ -f "$template" ]]; then
            mkdir -p "$prowlarr_custom_dir"
            sed "s/__PORT__/${app_port}/" "$template" > "${prowlarr_custom_dir}/mediafusion.yml"
            # Fix ownership to match Prowlarr's user
            local prowlarr_user
            prowlarr_user=$(stat -c '%U' "$(dirname "$prowlarr_custom_dir")")
            chown "${prowlarr_user}:${prowlarr_user}" "${prowlarr_custom_dir}/mediafusion.yml"
            echo_info "Deployed MediaFusion custom indexer to Prowlarr"
            # Restart Prowlarr to load the new definition
            systemctl restart prowlarr 2>/dev/null || true
        fi
    fi

    # Display manual instructions
    if command -v _display_prowlarr_torznab_info >/dev/null 2>&1; then
        _display_prowlarr_torznab_info "MediaFusion" "${torznab_url}" \
            "API Key: ${_mediafusion_api_password:-<see compose file>} (add via Custom indexer in Prowlarr)"
    fi
}

# ==============================================================================
# Post-Install Info
# ==============================================================================
_post_install_info() {
    echo ""
    echo_info "MediaFusion installed with 5 containers"
    echo_warn "Background scrapers are initializing - results may be limited for 30-60 minutes"
    echo ""
    echo_info "Web UI: https://your-server/mediafusion/"
    echo_info "API Password: ${_mediafusion_api_password:-<see compose file>}"
    echo_info "Torznab URL: http://127.0.0.1:${app_port}/torznab"

    # Show enabled scrapers summary
    local _enabled_scrapers=()
    grep -q 'IS_SCRAP_FROM_PROWLARR: "true"' "${app_dir}/docker-compose.yml" 2>/dev/null && _enabled_scrapers+=("Prowlarr")
    grep -q 'IS_SCRAP_FROM_JACKETT: "true"' "${app_dir}/docker-compose.yml" 2>/dev/null && _enabled_scrapers+=("Jackett")
    grep -q 'IS_SCRAP_FROM_ZILEAN: "true"' "${app_dir}/docker-compose.yml" 2>/dev/null && _enabled_scrapers+=("Zilean")
    grep -q 'IS_SCRAP_FROM_TORRENTIO: "true"' "${app_dir}/docker-compose.yml" 2>/dev/null && _enabled_scrapers+=("Torrentio")
    grep -q 'IS_SCRAP_FROM_PUBLIC_INDEXERS: "true"' "${app_dir}/docker-compose.yml" 2>/dev/null && _enabled_scrapers+=("Public indexers")
    grep -q 'IS_SCRAP_FROM_DMM_HASHLIST: "true"' "${app_dir}/docker-compose.yml" 2>/dev/null && _enabled_scrapers+=("DMM hashlist")
    if [[ ${#_enabled_scrapers[@]} -gt 0 ]]; then
        echo_info "Enabled scrapers: ${_enabled_scrapers[*]}"
    fi
    echo ""
    echo_info "To manually trigger scrapers, visit the web UI scraper control page"
    echo ""
}

# ==============================================================================
# Update
# ==============================================================================
_update_mediafusion() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Pulling latest ${app_pretty} images"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest images"
        exit 1
    }
    echo_progress_done "Latest images pulled"

    echo_progress_start "Recreating ${app_pretty} containers"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_mediafusion() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration (skip prompt if --force)
    local purgeconfig
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove all containers
    echo_progress_start "Stopping ${app_pretty} containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

    # Remove all Docker images
    echo_progress_start "Removing Docker images"
    docker rmi mhdzumair/mediafusion:latest >>"$log" 2>&1 || true
    docker rmi postgres:18-alpine >>"$log" 2>&1 || true
    docker rmi redis:7-alpine >>"$log" 2>&1 || true
    docker rmi ghcr.io/germondai/trawl:latest >>"$log" 2>&1 || true
    echo_progress_done "Docker images removed"

    # Remove Docker network
    docker network rm mediafusion-net 2>/dev/null || true

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
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

    # Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        swizdb clear "${app_name}/pg_port" 2>/dev/null || true
        swizdb clear "${app_name}/redis_port" 2>/dev/null || true
        swizdb clear "${app_name}/browser_port" 2>/dev/null || true
        swizdb clear "${app_name}/trawl_port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_dir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Usage
# ==============================================================================
_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  (no args)             Interactive setup"
    echo "  --update [--verbose]  Pull latest Docker images"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
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
    "--update")
        _update_mediafusion
        ;;
    "--remove")
        _remove_mediafusion "${2:-}"
        ;;
    "--register-panel")
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
        ;;
    "")
        # Interactive install (fall through to install logic below)
        ;;
    *)
        _usage
        ;;
esac

# ==============================================================================
# Install Logic
# ==============================================================================
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    _cleanup_needed=true

    # Pre-install RAM check
    _check_ram

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    # Run installation
    _install_docker
    _install_mediafusion
    _systemd_mediafusion
    _nginx_mediafusion
    _configure_prowlarr
    _post_install_info

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

    # Create lock file
    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
    _cleanup_needed=false

    echo_success "${app_pretty} installed"
fi
