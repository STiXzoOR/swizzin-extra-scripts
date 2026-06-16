#!/bin/bash
set -euo pipefail
# libretranslate installer
# STiXzoOR 2026
# Usage: bash libretranslate.sh [--subdomain [--revert]|--update|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true
# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

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

app_name="libretranslate"

# Get owner from swizdb (needed for both install and remove)
if ! LIBRETRANSLATE_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    LIBRETRANSLATE_OWNER="$(_get_master_username)"
fi
user="$LIBRETRANSLATE_OWNER"
app_group="$user"

# Port allocation (dynamic, stored in swizdb)
app_port=""

app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_configdir="$app_dir/config"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/libretranslate.png"

backup_dir="/opt/swizzin-extras/${app_name}-backups"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin-extras/organizr-auth.conf"

# ==============================================================================
# Language Definitions
# ==============================================================================

declare -A LANGUAGES=(
    ["en"]="English"
    ["es"]="Spanish"
    ["fr"]="French"
    ["de"]="German"
    ["it"]="Italian"
    ["pt"]="Portuguese"
    ["ru"]="Russian"
    ["zh"]="Chinese"
    ["ja"]="Japanese"
    ["ko"]="Korean"
    ["ar"]="Arabic"
    ["hi"]="Hindi"
    ["nl"]="Dutch"
    ["pl"]="Polish"
    ["tr"]="Turkish"
    ["vi"]="Vietnamese"
    ["uk"]="Ukrainian"
    ["cs"]="Czech"
    ["da"]="Danish"
    ["fi"]="Finnish"
    ["el"]="Greek"
    ["he"]="Hebrew"
    ["hu"]="Hungarian"
    ["id"]="Indonesian"
    ["sv"]="Swedish"
    ["th"]="Thai"
    ["bg"]="Bulgarian"
    ["ca"]="Catalan"
    ["et"]="Estonian"
    ["ga"]="Irish"
    ["lv"]="Latvian"
    ["lt"]="Lithuanian"
    ["ro"]="Romanian"
    ["sk"]="Slovak"
    ["sl"]="Slovenian"
    ["sq"]="Albanian"
    ["az"]="Azerbaijani"
    ["eu"]="Basque"
    ["bn"]="Bengali"
    ["eo"]="Esperanto"
    ["gl"]="Galician"
    ["ky"]="Kyrgyz"
    ["ms"]="Malay"
    ["nb"]="Norwegian"
    ["fa"]="Persian"
    ["tl"]="Tagalog"
    ["ur"]="Urdu"
    ["zt"]="Chinese (Traditional)"
    ["pb"]="Portuguese (Brazil)"
)

# Display order (common languages first)
LANGUAGE_ORDER=(en es fr de it pt ru zh ja ko ar hi nl pl tr vi uk th sv
    'fi' da cs el he hu id ro bg ca et ga lv lt sk sl sq az eu
    bn eo gl ky ms nb fa tl ur zt pb)

# --- Function definitions ---

# ==============================================================================
# Domain / LE / State Helpers
# ==============================================================================

_get_organizr_domain() {
    if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
        grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
    fi
}

_get_domain() {
    local swizdb_domain
    swizdb_domain=$(swizdb get "${app_name}/domain" 2>/dev/null) || true
    if [ -n "$swizdb_domain" ]; then
        echo "$swizdb_domain"
        return
    fi
    echo "${LIBRETRANSLATE_DOMAIN:-}"
}

_prompt_domain() {
    if [ -n "${LIBRETRANSLATE_DOMAIN:-}" ]; then
        echo_info "Using domain from LIBRETRANSLATE_DOMAIN: $LIBRETRANSLATE_DOMAIN"
        app_domain="$LIBRETRANSLATE_DOMAIN"
        return
    fi

    local existing_domain
    existing_domain=$(_get_domain)

    if [ -n "$existing_domain" ]; then
        echo_query "Enter domain for LibreTranslate" "[$existing_domain]"
    else
        echo_query "Enter domain for LibreTranslate" "(e.g., translate.example.com)"
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
    export LIBRETRANSLATE_DOMAIN="$app_domain"
}

_prompt_le_mode() {
    if [ -n "${LIBRETRANSLATE_LE_INTERACTIVE:-}" ]; then
        echo_info "Using LE mode from LIBRETRANSLATE_LE_INTERACTIVE: $LIBRETRANSLATE_LE_INTERACTIVE"
        return
    fi

    if ask "Use interactive Let's Encrypt (for DNS challenges/wildcards)?" N; then
        export LIBRETRANSLATE_LE_INTERACTIVE="yes"
    else
        export LIBRETRANSLATE_LE_INTERACTIVE="no"
    fi
}

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
# Let's Encrypt Certificate
# ==============================================================================

_request_certificate() {
    local domain="$1"
    local le_hostname="${LIBRETRANSLATE_LE_HOSTNAME:-$domain}"
    local cert_dir="/etc/nginx/ssl/$le_hostname"
    local le_interactive="${LIBRETRANSLATE_LE_INTERACTIVE:-no}"

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
        echo_error "Check $log for details or run manually: LE_HOSTNAME=$le_hostname box install letsencrypt"
        exit 1
    fi

    echo_info "Let's Encrypt certificate issued for $le_hostname"
}

# ==============================================================================
# Organizr Integration
# ==============================================================================

_exclude_from_organizr() {
    local modified=false
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"

    if [ -f "$organizr_config" ] && grep -q "^${app_name}:" "$organizr_config"; then
        echo_progress_start "Removing ${app_name^} from Organizr protected apps"
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

_include_in_organizr() {
    if [ -f "$organizr_config" ] && ! grep -q "^${app_name}:" "$organizr_config"; then
        echo_info "Note: ${app_name^} can be re-added to Organizr protection via: bash organizr.sh --configure"
    fi
}

# ==============================================================================
# GPU Detection
# ==============================================================================

_detect_gpu() {
    # Allow override via environment variable
    if [[ -n "${LIBRETRANSLATE_GPU:-}" ]]; then
        echo "${LIBRETRANSLATE_GPU}"
        return
    fi

    # Check for NVIDIA GPU
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        # Check for nvidia-container-toolkit
        if docker info 2>/dev/null | grep -qi "nvidia"; then
            echo "cuda"
            return
        fi
    fi
    echo "cpu"
}

# ==============================================================================
# Language Selection
# ==============================================================================

_prompt_languages() {
    # Check for environment variable override
    if [[ -n "${LIBRETRANSLATE_LANGUAGES:-}" ]]; then
        SELECTED_LANGUAGES="$LIBRETRANSLATE_LANGUAGES"
        echo_info "Using languages from LIBRETRANSLATE_LANGUAGES: $SELECTED_LANGUAGES"
        swizdb set "${app_name}/languages" "$SELECTED_LANGUAGES"
        return
    fi

    # Check for previously selected languages
    local existing_languages
    existing_languages=$(swizdb get "${app_name}/languages" 2>/dev/null) || true

    if command -v whiptail &>/dev/null; then
        _prompt_languages_whiptail "$existing_languages"
    else
        _prompt_languages_fallback "$existing_languages"
    fi
}

_prompt_languages_whiptail() {
    local existing="$1"
    local options=()

    # Build options array
    for code in "${LANGUAGE_ORDER[@]}"; do
        local name="${LANGUAGES[$code]}"
        # Pre-select English by default, or previous selections
        if [[ -n "$existing" && "$existing" == *"$code"* ]]; then
            options+=("$code" "$name" "ON")
        elif [[ -z "$existing" && "$code" == "en" ]]; then
            options+=("$code" "$name" "ON")
        else
            options+=("$code" "$name" "OFF")
        fi
    done

    local selected
    selected=$(whiptail --title "Language Selection" \
        --checklist "Select languages to pre-download:\n(Models are 200-500MB each)\n\nSpace to toggle, Enter to confirm" \
        25 50 15 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) || {
        echo_info "Cancelled, defaulting to English only"
        SELECTED_LANGUAGES="en"
        swizdb set "${app_name}/languages" "$SELECTED_LANGUAGES"
        return
    }

    # Convert "en" "es" "fr" to en,es,fr
    SELECTED_LANGUAGES=$(echo "$selected" | tr -d '"' | tr ' ' ',')
    [[ -z "$SELECTED_LANGUAGES" ]] && SELECTED_LANGUAGES="en"

    swizdb set "${app_name}/languages" "$SELECTED_LANGUAGES"
    echo_info "Selected languages: $SELECTED_LANGUAGES"
}

_prompt_languages_fallback() {
    local existing="$1"

    echo_info "Available languages:"
    echo_info "  Common: en, es, fr, de, it, pt, ru, zh, ja, ko, ar, hi"
    echo_info "  More:   nl, pl, tr, vi, uk, th, sv, fi, da, cs, el, he, hu, id"
    echo_info "  All:    ${LANGUAGE_ORDER[*]}"
    echo ""

    if [[ -n "$existing" ]]; then
        echo_query "Enter languages to pre-download (comma-separated)" "[$existing]"
    else
        echo_query "Enter languages to pre-download (comma-separated)" "[en]"
    fi
    read -r input </dev/tty

    if [[ -z "$input" ]]; then
        if [[ -n "$existing" ]]; then
            SELECTED_LANGUAGES="$existing"
        else
            SELECTED_LANGUAGES="en"
        fi
    else
        SELECTED_LANGUAGES=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z,')
    fi

    swizdb set "${app_name}/languages" "$SELECTED_LANGUAGES"
    echo_info "Selected languages: $SELECTED_LANGUAGES"
}

# ==============================================================================
# Lingarr Integration
# ==============================================================================

_configure_lingarr() {
    if [[ ! -f /install/.lingarr.lock ]]; then
        return 0
    fi

    # Check for environment variable override
    if [[ "${LIBRETRANSLATE_CONFIGURE_LINGARR:-}" == "no" ]]; then
        echo_info "Skipping Lingarr integration (LIBRETRANSLATE_CONFIGURE_LINGARR=no)"
        return 0
    fi

    echo_info "Lingarr detected on this system"

    # Determine if we're using URL prefix (subfolder mode)
    local state
    state=$(_get_install_state)
    local url_suffix=""
    if [[ "$state" != "subdomain" ]]; then
        url_suffix="/$app_baseurl"
    fi

    local libretranslate_url="http://127.0.0.1:${app_port}${url_suffix}"

    if [[ "${LIBRETRANSLATE_CONFIGURE_LINGARR:-}" != "yes" ]]; then
        if ! ask "Configure Lingarr to use this LibreTranslate instance?" Y; then
            echo_info "Skipping Lingarr integration"
            echo_info "Manual config: Settings > Translation > LibreTranslate URL = $libretranslate_url"
            return 0
        fi
    fi

    local lingarr_compose="/opt/lingarr/docker-compose.yml"

    if [[ ! -f "$lingarr_compose" ]]; then
        echo_info "Lingarr docker-compose.yml not found"
        echo_info "Configure manually in Lingarr web UI:"
        echo_info "  Settings > Translation > LibreTranslate URL = $libretranslate_url"
        return 0
    fi

    echo_progress_start "Configuring Lingarr to use local LibreTranslate"

    local escaped_url
    escaped_url=$(_sed_escape_value "$libretranslate_url")

    # Check if LIBRE_TRANSLATE_URL is already in the compose file
    if grep -q "LIBRE_TRANSLATE_URL" "$lingarr_compose"; then
        # Update existing entry
        sed -i "s|LIBRE_TRANSLATE_URL=.*|LIBRE_TRANSLATE_URL=${escaped_url}|" "$lingarr_compose"
    else
        # Add LIBRE_TRANSLATE_URL before the volumes: line (after environment vars)
        if grep -q "^    volumes:" "$lingarr_compose"; then
            sed -i "/^    volumes:/i\\      - LIBRE_TRANSLATE_URL=${escaped_url}" "$lingarr_compose"
        elif grep -q "^    environment:" "$lingarr_compose"; then
            # No volumes section, append after environment section
            # Find last env var line and append after it
            local last_env_line
            last_env_line=$(grep -n "^      - " "$lingarr_compose" | tail -1 | cut -d: -f1)
            if [[ -n "$last_env_line" ]]; then
                sed -i "${last_env_line}a\\      - LIBRE_TRANSLATE_URL=${escaped_url}" "$lingarr_compose"
            fi
        fi
    fi

    echo_progress_done "Lingarr docker-compose.yml updated"

    # Recreate the Lingarr container to pick up the new environment variable
    echo_progress_start "Restarting Lingarr to apply changes"
    docker compose -f "$lingarr_compose" up -d >>"$log" 2>&1 || true
    echo_progress_done "Lingarr restarted"

    echo_info "Lingarr will use LibreTranslate at $libretranslate_url"
}

# ==============================================================================
# Docker / Install Functions
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

_install_libretranslate() {
    mkdir -p "$app_configdir/db"
    mkdir -p "$app_configdir/models"
    chown -R "${user}:${user}" "$app_dir"

    # Detect GPU
    local gpu_mode
    gpu_mode=$(_detect_gpu)
    echo_info "GPU mode: $gpu_mode"

    # Get selected languages
    local languages="${SELECTED_LANGUAGES:-en}"

    # Get install state to determine URL prefix
    local state
    state=$(_get_install_state)
    local url_prefix=""
    if [[ "$state" != "subdomain" ]]; then
        url_prefix="/$app_baseurl"
    fi

    echo_progress_start "Generating Docker Compose configuration"

    # Determine image and volume path based on GPU mode
    # Non-CUDA image runs as user 'libretranslate' (uid 1032)
    # CUDA image runs as root
    local docker_image="libretranslate/libretranslate:latest"
    local models_path="/home/libretranslate/.local"
    local container_uid=1032
    local container_gid=1032
    if [[ "$gpu_mode" == "cuda" ]]; then
        docker_image="libretranslate/libretranslate:latest-cuda"
        models_path="/root/.local"
        container_uid=0
        container_gid=0
    fi

    # Set ownership to match container's internal user
    chown -R "${container_uid}:${container_gid}" "$app_configdir"

    # Write docker-compose.yml
    {
        cat <<COMPOSE
services:
  libretranslate:
    image: ${docker_image}
    container_name: libretranslate
    restart: unless-stopped
    network_mode: host
    environment:
      - LT_HOST=127.0.0.1
      - LT_PORT=${app_port}
      - LT_LOAD_ONLY=${languages}
      - LT_UPDATE_MODELS=true
COMPOSE

        # Add URL prefix for subfolder mode
        if [[ -n "$url_prefix" ]]; then
            echo "      - LT_URL_PREFIX=${url_prefix}"
        fi

        echo "    volumes:"
        echo "      - ${app_configdir}/db:/app/db"
        echo "      - ${app_configdir}/models:${models_path}"

        # Add GPU configuration for CUDA
        if [[ "$gpu_mode" == "cuda" ]]; then
            cat <<CUDA
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
CUDA
        fi
    } >"$app_dir/docker-compose.yml"

    # Store GPU mode in swizdb for updates
    swizdb set "${app_name}/gpu_mode" "$gpu_mode"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling LibreTranslate Docker image"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting LibreTranslate container"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "LibreTranslate container started"

    echo_info "Note: First startup may take several minutes while language models download"
}

_systemd_libretranslate() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=LibreTranslate (Machine Translation API)
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
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

_nginx_libretranslate() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_baseurl {
			  return 301 /$app_baseurl/;
			}

			location ^~ /$app_baseurl/ {
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_read_timeout 300s;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			# API endpoints bypass auth for programmatic access
			location ^~ /$app_baseurl/translate {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/translate;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_read_timeout 300s;
			}

			location ^~ /$app_baseurl/languages {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/languages;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}

			location ^~ /$app_baseurl/detect {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/detect;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
    fi
}

# ==============================================================================
# Fresh Install (subfolder mode)
# ==============================================================================

_install_fresh() {
    if [[ -f "/install/.$app_lockname.lock" ]]; then
        echo_info "${app_name^} already installed"
        return
    fi

    # Set owner for install
    if [[ -n "${LIBRETRANSLATE_OWNER:-}" ]]; then
        echo_info "Setting ${app_name^} owner = $LIBRETRANSLATE_OWNER"
        swizdb set "$app_name/owner" "$LIBRETRANSLATE_OWNER"
    fi

    # Allocate port
    app_port=$(port 10000 12000)
    swizdb set "$app_name/port" "$app_port"
    echo_info "Allocated port: $app_port"

    _install_docker
    _prompt_languages
    _install_libretranslate
    _systemd_libretranslate
    _nginx_libretranslate

    # Configure Lingarr integration
    _configure_lingarr

    # Panel registration (subfolder mode)
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "LibreTranslate" \
            "/$app_baseurl" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    fi

    touch "/install/.$app_lockname.lock"
    echo_success "${app_name^} installed"
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

    ${csp_header}

    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
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

    # Remove existing class if present (standalone class, not inheritance)
    sed -i "/^class ${app_name}_meta:/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

    # LibreTranslate is NOT a built-in Swizzin app, so create standalone class (no inheritance)
    cat >>"$profiles_py" <<PYTHON

class ${app_name}_meta:
    name = "${app_name}"
    pretty_name = "LibreTranslate"
    urloverride = "https://${domain}"
    systemd = "${app_name}"
    img = "${app_icon_name}"
    check_theD = True
PYTHON

    echo_progress_done "Panel meta updated"
}

_remove_panel_meta() {
    if [ -f "$profiles_py" ]; then
        echo_progress_start "Removing panel meta urloverride"
        # Remove standalone class (not inheritance)
        sed -i "/^class ${app_name}_meta:/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
        echo_progress_done "Panel meta removed"
    fi
}

# ==============================================================================
# Subdomain Install / Revert
# ==============================================================================

_install_subdomain() {
    _prompt_domain
    _prompt_le_mode

    local domain
    domain=$(_get_domain)
    local le_hostname="${LIBRETRANSLATE_LE_HOSTNAME:-$domain}"
    local state
    state=$(_get_install_state)

    # Get port from swizdb
    app_port=$(swizdb get "$app_name/port" 2>/dev/null) || true

    echo_info "${app_name^} Subdomain Setup"
    echo_info "Domain: $domain"
    [ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
    echo_info "Current state: $state"

    case "$state" in
        "not_installed")
            _install_fresh
            ;& # fallthrough
        "installed")
            # Backup subfolder config before switching
            _backup_file "/etc/nginx/apps/$app_name.conf"
            # Remove subfolder config (subdomain replaces it)
            _remove_nginx_conf "$app_name"

            # Update docker-compose to remove URL prefix
            if [[ -f "$app_dir/docker-compose.yml" ]]; then
                sed -i '/LT_URL_PREFIX/d' "$app_dir/docker-compose.yml"
                # Restart container to pick up change
                docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || true
            fi

            _request_certificate "$domain"
            _create_subdomain_vhost "$domain" "$le_hostname"
            _add_panel_meta "$domain"
            _exclude_from_organizr
            _reload_nginx
            echo_success "${app_name^} converted to subdomain mode"
            echo_info "Access at: https://$domain"
            ;;
        "subdomain")
            echo_info "Already in subdomain mode"
            ;;
    esac
}

_revert_subdomain() {
    echo_info "Reverting ${app_name^} to subfolder mode..."

    # Get port from swizdb
    app_port=$(swizdb get "$app_name/port" 2>/dev/null) || true

    [ -L "$subdomain_enabled" ] && rm -f "$subdomain_enabled"
    [ -f "$subdomain_vhost" ] && rm -f "$subdomain_vhost"

    # Update docker-compose to add URL prefix back
    if [[ -f "$app_dir/docker-compose.yml" ]]; then
        if ! grep -q "LT_URL_PREFIX" "$app_dir/docker-compose.yml"; then
            # Add URL prefix after LT_UPDATE_MODELS line
            sed -i "/LT_UPDATE_MODELS/a\\      - LT_URL_PREFIX=/$app_baseurl" "$app_dir/docker-compose.yml"
        fi
        # Restart container to pick up change
        docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || true
    fi

    # Restore subfolder nginx config
    if [ -f "$backup_dir/$app_name.conf.bak" ]; then
        cp "$backup_dir/$app_name.conf.bak" "/etc/nginx/apps/$app_name.conf"
        echo_info "Restored subfolder nginx config from backup"
    elif [ -f /install/.nginx.lock ]; then
        echo_info "Recreating subfolder config..."
        _nginx_libretranslate
    fi

    _remove_panel_meta
    _include_in_organizr

    _reload_nginx
    echo_success "${app_name^} reverted to subfolder mode"
    echo_info "Access at: https://your-server/$app_baseurl/"
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
    echo_info "${app_name^} Setup"

    local state
    state=$(_get_install_state)

    if [ "$state" = "not_installed" ]; then
        _install_fresh
        state="installed"
    else
        echo_info "${app_name^} already installed"
        # Load port from swizdb
        app_port=$(swizdb get "$app_name/port" 2>/dev/null) || true
    fi

    if [ "$state" = "installed" ]; then
        if [ -f /install/.nginx.lock ]; then
            if ask "Configure LibreTranslate with a subdomain? (recommended for cleaner URLs)" N; then
                _install_subdomain
            fi
        fi
    elif [ "$state" = "subdomain" ]; then
        echo_info "Subdomain already configured"
    fi

    echo_success "${app_name^} setup complete"
}

# ==============================================================================
# Usage
# ==============================================================================

_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  (no args)             Interactive setup"
    echo "  --subdomain           Convert to subdomain mode"
    echo "  --subdomain --revert  Revert to subfolder mode"
    echo "  --update [--verbose]  Pull latest Docker image"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
}

# ==============================================================================
# Update
# ==============================================================================

_update_libretranslate() {
    if [[ ! -f "/install/.$app_lockname.lock" ]]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_name^}..."

    echo_progress_start "Pulling latest LibreTranslate image"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating LibreTranslate container"
    _verbose "Running: docker compose up -d"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_name^} has been updated"
    exit 0
}

_remove_libretranslate() {
    local force="$1"
    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.$app_lockname.lock" ]]; then
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

    # Stop and remove container
    echo_progress_start "Stopping LibreTranslate container"
    if [[ -f "$app_dir/docker-compose.yml" ]]; then
        docker compose -f "$app_dir/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi libretranslate/libretranslate >>"$log" 2>&1 || true
    docker rmi libretranslate/libretranslate:latest-cuda >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/$app_servicefile"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove subfolder nginx config
    if [[ -f "/etc/nginx/apps/$app_name.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        _remove_nginx_conf "$app_name"
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove subdomain vhost if exists
    if [ -f "$subdomain_vhost" ] || [ -L "$subdomain_enabled" ]; then
        echo_progress_start "Removing subdomain nginx configuration"
        rm -f "$subdomain_enabled"
        rm -f "$subdomain_vhost"
        echo_progress_done "Subdomain configuration removed"
    fi

    _reload_nginx 2>/dev/null || true

    # Remove panel meta (subdomain mode)
    _remove_panel_meta

    # Remove from panel (subfolder mode)
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
        swizdb clear "$app_name/owner" 2>/dev/null || true
        swizdb clear "$app_name/port" 2>/dev/null || true
        swizdb clear "$app_name/domain" 2>/dev/null || true
        swizdb clear "$app_name/languages" 2>/dev/null || true
        swizdb clear "$app_name/gpu_mode" 2>/dev/null || true
    else
        echo_info "Configuration kept at: $app_configdir"
        rm -f "$app_dir/docker-compose.yml"
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
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
    "--subdomain")
        case "${2:-}" in
            "--revert") _revert_subdomain ;;
            "") _install_subdomain ;;
            *) _usage ;;
        esac
        ;;
    "--update")
        _update_libretranslate
        ;;
    "--remove")
        _remove_libretranslate "$2"
        ;;
    "--register-panel")
        if [[ ! -f "/install/.$app_lockname.lock" ]]; then
            echo_error "${app_name^} is not installed"
            exit 1
        fi
        state=$(_get_install_state)
        if [ "$state" = "subdomain" ]; then
            domain=$(_get_domain)
            if [ -n "$domain" ]; then
                _add_panel_meta "$domain"
            else
                echo_error "No domain configured"
                exit 1
            fi
        else
            _load_panel_helper
            if command -v panel_register_app >/dev/null 2>&1; then
                panel_register_app \
                    "$app_name" \
                    "LibreTranslate" \
                    "/$app_baseurl" \
                    "" \
                    "$app_name" \
                    "$app_icon_name" \
                    "$app_icon_url" \
                    "true"
            else
                echo_error "Panel helper not available"
                exit 1
            fi
        fi
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_name^}"
        ;;
    "")
        _interactive
        ;;
    *)
        _usage
        ;;
esac
