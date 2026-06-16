#!/bin/bash
# subgen installer
# STiXzoOR 2025
# Usage: bash subgen.sh [--remove [--force]] [--update [--full] [--verbose]] [--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

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
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

app_name="subgen"

# Get owner from swizdb (needed for both install and remove)
if ! SUBGEN_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    SUBGEN_OWNER="$(_get_master_username)"
fi
user="$SUBGEN_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "git" "ffmpeg")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_icon_name="$app_name"
app_icon_url="https://raw.githubusercontent.com/McCloudS/subgen/main/icon.png"

if [ ! -d "$swiz_configdir" ]; then
    mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

_install_uv() {
    # Install uv for the app user if not present
    if su - "$user" -c 'command -v uv >/dev/null 2>&1'; then
        echo_info "uv already installed for $user"
        return 0
    fi

    echo_progress_start "Installing uv for $user"
    su - "$user" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >>"$log" 2>&1 || {
        echo_error "Failed to install uv"
        exit 1
    }
    echo_progress_done "uv installed"
}

_prompt_whisper_model() {
    # Allow bypassing with environment variable
    if [ -n "$SUBGEN_MODEL" ]; then
        whisper_model="$SUBGEN_MODEL"
        echo_info "Using Whisper model from environment: $whisper_model"
        return
    fi

    # Detect if GPU is available for model recommendations
    local has_gpu=false
    if nvidia-smi &>/dev/null; then
        has_gpu=true
    fi

    # Model options with descriptions (memory requirements are approximate)
    local default_model="medium"
    if [ "$has_gpu" = true ]; then
        default_model="medium"
    else
        default_model="small"
    fi

    whisper_model=$(whiptail --title "Whisper Model Selection" --menu \
        "Select the Whisper model for transcription.\n\nLarger models are more accurate but slower and use more memory.\nRecommended: $default_model (based on your hardware)" \
        20 78 10 \
        "tiny" "~75MB VRAM - Fastest, lowest accuracy" \
        "base" "~150MB VRAM - Fast, basic accuracy" \
        "small" "~500MB VRAM - Good balance (Recommended for CPU)" \
        "medium" "~2GB VRAM - High accuracy (Recommended for GPU)" \
        "large-v3" "~5GB VRAM - Highest accuracy, slowest" \
        "large-v3-turbo" "~5GB VRAM - High accuracy, faster than large-v3" \
        "distil-large-v3" "~3GB VRAM - Distilled, good speed/accuracy" \
        "distil-medium.en" "~1GB VRAM - English-only, fast" \
        3>&1 1>&2 2>&3) || whisper_model="$default_model"

    if [ -z "$whisper_model" ]; then
        whisper_model="$default_model"
    fi

    echo_info "Selected Whisper model: $whisper_model"
}

_install_subgen() {
    if [ ! -d "$app_configdir" ]; then
        mkdir -p "$app_configdir"
    fi
    chown -R "$user":"$user" "$app_configdir"

    apt_install "${app_reqs[@]}"

    _install_uv

    echo_progress_start "Cloning ${app_name^} repository"

    if [ -d "$app_dir" ]; then
        rm -rf "$app_dir"
    fi

    git clone https://github.com/McCloudS/subgen.git "$app_dir" >>"$log" 2>&1 || {
        echo_error "Failed to clone ${app_name^} repository"
        exit 1
    }
    chown -R "$user":"$user" "$app_dir"
    echo_progress_done "Repository cloned"

    echo_progress_start "Installing ${app_name^} dependencies"

    # Create pyproject.toml for uv if only requirements.txt exists
    if [ -f "$app_dir/requirements.txt" ] && [ ! -f "$app_dir/pyproject.toml" ]; then
        # Build dependencies array from requirements.txt (strip comments)
        deps_array=$(grep -vE '^\s*#|^\s*$' "$app_dir/requirements.txt" | sed 's/\s*#.*//' | sed 's/.*/"&",/' | tr '\n' ' ' | sed 's/, $//')
        cat >"$app_dir/pyproject.toml" <<PYPROJ
[project]
name = "subgen"
version = "0.0.0"
requires-python = ">=3.11"
dependencies = [$deps_array]
PYPROJ
    fi

    su - "$user" -c "cd '$app_dir' && uv python install 3.11" >>"$log" 2>&1 || {
        echo_error "Failed to install Python 3.11"
        exit 1
    }

    su - "$user" -c "cd '$app_dir' && uv sync --python 3.11" >>"$log" 2>&1 || {
        echo_error "Failed to install ${app_name^} dependencies"
        exit 1
    }

    echo_progress_done "Dependencies installed"

    # Detect GPU (nvidia-smi confirms both hardware and working drivers)
    if nvidia-smi &>/dev/null; then
        transcribe_device="gpu"
        echo_info "NVIDIA GPU detected — using GPU for transcription"
    else
        transcribe_device="cpu"
        echo_info "No NVIDIA GPU detected — using CPU for transcription"
    fi

    # Detect CPU thread count for Whisper
    cpu_threads=$(nproc 2>/dev/null || echo 4)
    if [ "$cpu_threads" -gt 8 ]; then
        cpu_threads=8
    fi

    # Prompt for Whisper model selection
    _prompt_whisper_model

    # Create env file with sensible defaults
    # Both systemd (EnvironmentFile) and launcher.py (load_env_variables) read this
    cat >"$app_configdir/env.conf" <<EOF
# Subgen environment
# Webhook port for Plex/Jellyfin/Emby notifications
WEBHOOK_PORT=$app_port

# Whisper settings
WHISPER_MODEL=$whisper_model
TRANSCRIBE_DEVICE=$transcribe_device
WHISPER_THREADS=$cpu_threads

# Subtitle settings
WORD_LEVEL_HIGHLIGHT=False
SUBTITLE_FORMAT=srt

# Debug
DEBUG=False
CLEAR_VRAM_ON_COMPLETE=False
APPEND=False
EOF

    chown -R "$user":"$user" "$app_configdir"

    # Symlink subgen.env to env.conf so launcher.py finds it in the working directory
    ln -sf "$app_configdir/env.conf" "$app_dir/subgen.env"
    echo_info "Configure Plex/Jellyfin/Emby webhook to: http://<server>:$app_port/webhook"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_subgen() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    _verbose "Creating backup directory: ${backup_dir}"
    mkdir -p "$backup_dir"

    if [[ -d "$app_dir" ]]; then
        _verbose "Backing up application directory: ${app_dir}"
        cp -r "$app_dir" "${backup_dir}/app"
        _verbose "Backup complete ($(du -sh "${backup_dir}/app" | cut -f1))"
    else
        echo_error "Application directory not found: ${app_dir}"
        return 1
    fi
}

# ==============================================================================
# Rollback (restore from backup on failed update)
# ==============================================================================
_rollback_subgen() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"

    echo_error "Update failed, rolling back..."

    if [[ -d "${backup_dir}/app" ]]; then
        _verbose "Restoring application from backup"
        rm -rf "$app_dir"
        cp -r "${backup_dir}/app" "$app_dir"
        chown -R "${user}:${user}" "$app_dir"

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
_update_subgen() {
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

        rm -rf "$app_dir"
        _install_subgen

        echo_progress_start "Starting service"
        systemctl start "$app_servicefile"
        echo_progress_done "Service started"
        echo_success "${app_name^} reinstalled"
        exit 0
    fi

    # Smart update (git pull + uv sync)
    echo_info "Updating ${app_name^}..."

    echo_progress_start "Backing up current installation"
    if ! _backup_subgen; then
        echo_error "Backup failed, aborting update"
        exit 1
    fi
    echo_progress_done "Backup created"

    echo_progress_start "Stopping service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Pulling latest code"
    _verbose "Running: git -C ${app_dir} pull"
    if ! su - "$user" -c "cd '${app_dir}' && git pull" >>"$log" 2>&1; then
        echo_error "Git pull failed"
        _rollback_subgen
        exit 1
    fi
    echo_progress_done "Code updated"

    echo_progress_start "Updating dependencies"
    _verbose "Running: uv sync"
    if ! su - "$user" -c "cd '${app_dir}' && uv sync" >>"$log" 2>&1; then
        echo_error "Dependency update failed"
        _rollback_subgen
        exit 1
    fi
    echo_progress_done "Dependencies updated"

    echo_progress_start "Restarting service"
    systemctl start "$app_servicefile"

    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_progress_done "Service running"
        _verbose "Service status: active"
    else
        echo_progress_done "Service may have issues"
        _rollback_subgen
        exit 1
    fi

    rm -rf "/tmp/swizzin-update-backups/${app_name}"
    echo_success "${app_name^} updated"
    exit 0
}

_remove_subgen() {
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

    # Remove application directory
    echo_progress_start "Removing ${app_name^} application"
    rm -rf "$app_dir"
    echo_progress_done "Application removed"

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

_systemd_subgen() {
    echo_progress_start "Installing Systemd service"

    cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Automatic subtitle generation using Whisper
After=network.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_dir
EnvironmentFile=$app_configdir/env.conf
ExecStart=/home/${user}/.local/bin/uv run python -u subgen.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable --now -q "$app_servicefile"
    sleep 1
    echo_progress_done "${app_name^} service installed and enabled"
    echo_info "${app_name^} webhook available at http://127.0.0.1:$app_port/webhook"
}

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

# Handle --update flag
if [[ "$1" == "--update" ]]; then
    full_reinstall=false
    for arg in "$@"; do
        case "$arg" in
            --full) full_reinstall=true ;;
        esac
    done
    _update_subgen "$full_reinstall"
fi

# Handle --remove flag
if [ "$1" = "--remove" ]; then
    _remove_subgen "$2"
fi

# Handle --register-panel flag
if [ "$1" = "--register-panel" ]; then
    if [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "Subgen" \
            "" \
            "http://127.0.0.1:$app_port" \
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
    if [ -n "$SUBGEN_OWNER" ]; then
        echo_info "Setting ${app_name^} owner = $SUBGEN_OWNER"
        swizdb set "$app_name/owner" "$SUBGEN_OWNER"
    fi

    _install_subgen
    _systemd_subgen
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Subgen" \
        "" \
        "http://127.0.0.1:$app_port" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
