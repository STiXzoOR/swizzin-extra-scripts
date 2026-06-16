#!/bin/bash
#===============================================================================
# Swizzin Backup Setup Wizard (BorgBackup)
# Automates setup for any SSH-accessible borg repository
#
# Usage:
#   bash swizzin-backup-install.sh              Interactive setup wizard
#   bash swizzin-backup-install.sh --status     Show current setup status
#   bash swizzin-backup-install.sh --remove     Remove deployed files (not remote repo)
#   bash swizzin-backup-install.sh --help       Show help
#===============================================================================

set -euo pipefail

readonly TOTAL_STEPS=10

# Paths
readonly SSH_KEY="/root/.ssh/id_backup"
readonly PASSPHRASE_FILE="/root/.swizzin-backup-passphrase"
readonly KEY_EXPORT="/root/swizzin-backup-key-export.txt"
readonly CONF_FILE="/etc/swizzin-backup.conf"
readonly EXCLUDES_TARGET="/etc/swizzin-excludes.txt"
readonly BACKUP_SCRIPT="/usr/local/bin/swizzin-backup.sh"
readonly RESTORE_SCRIPT="/usr/local/bin/swizzin-restore.sh"
readonly SERVICE_FILE="/etc/systemd/system/swizzin-backup.service"
readonly TIMER_FILE="/etc/systemd/system/swizzin-backup.timer"
readonly LOGROTATE_FILE="/etc/logrotate.d/swizzin-backup"
readonly VERIFY_SERVICE_FILE="/etc/systemd/system/swizzin-backup-verify.service"
readonly VERIFY_TIMER_FILE="/etc/systemd/system/swizzin-backup-verify.timer"
readonly NOTIFICATIONS_LIB="/usr/local/lib/swizzin/notifications.sh"

# State shared across setup steps
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_PORT="22"
BORG_REPO_URL=""

# ==============================================================================
# Colors and Formatting
# ==============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# ==============================================================================
# Logging Functions
# ==============================================================================

echo_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[OK]${NC} $1"; }
echo_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo_header() {
    local title="$1"
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $title${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

echo_step() {
    local step="$1"
    local total="$2"
    local message="$3"
    echo ""
    echo -e "${BOLD}[${step}/${total}]${NC} ${BOLD}$message${NC}"
    echo ""
}

# ==============================================================================
# Progress Indicators
# ==============================================================================

_spinner_pid=""

_start_spinner() {
    local message="$1"
    echo -ne "${BLUE}[...]${NC} $message "

    (
        local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        while true; do
            for (( i=0; i<${#chars}; i++ )); do
                echo -ne "\r${BLUE}[${chars:$i:1}]${NC} $message "
                sleep 0.1
            done
        done
    ) &
    _spinner_pid=$!
    disown
}

_stop_spinner() {
    local status="$1"
    local message="$2"

    if [[ -n "$_spinner_pid" ]]; then
        kill "$_spinner_pid" 2>/dev/null
        wait "$_spinner_pid" 2>/dev/null
        _spinner_pid=""
    fi

    echo -ne "\r\033[K"
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN}[OK]${NC} $message"
    else
        echo -e "${RED}[FAIL]${NC} $message"
    fi
}

echo_progress_start() {
    local message="$1"
    if [[ -t 1 ]]; then
        _start_spinner "$message"
    else
        echo_info "$message..."
    fi
}

echo_progress_done() {
    local message="${1:-Done}"
    if [[ -t 1 ]]; then
        _stop_spinner "success" "$message"
    else
        echo_success "$message"
    fi
}

echo_progress_fail() {
    local message="${1:-Failed}"
    if [[ -t 1 ]]; then
        _stop_spinner "fail" "$message"
    else
        echo_error "$message"
    fi
}

# ==============================================================================
# User Prompts
# ==============================================================================

ask() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -rp "$prompt [Y/n]: " answer </dev/tty
        [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
    else
        read -rp "$prompt [y/N]: " answer </dev/tty
        [[ "$answer" =~ ^[Yy] ]]
    fi
}

prompt_value() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " value </dev/tty
        echo "${value:-$default}"
    else
        read -rp "$prompt: " value </dev/tty
        echo "$value"
    fi
}

# ==============================================================================
# Utility Functions
# ==============================================================================

command_exists() {
    command -v "$1" &>/dev/null
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run as root"
        exit 1
    fi
}

_detect_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [[ -L "$source" ]]; do
        local dir
        dir=$(cd -P "$(dirname "$source")" &>/dev/null && pwd)
        source=$(readlink "$source")
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" &>/dev/null && pwd
}

_detect_swizzin_user() {
    local user=""

    # Method 1: Swizzin utils
    if [[ -f /etc/swizzin/sources/globals.sh ]]; then
        # shellcheck source=/dev/null
        . /etc/swizzin/sources/globals.sh 2>/dev/null || true
        if type _get_master_username &>/dev/null 2>&1; then
            user=$(_get_master_username 2>/dev/null) || true
        fi
    fi

    # Method 2: htpasswd
    if [[ -z "$user" && -f /etc/htpasswd ]]; then
        user=$(head -1 /etc/htpasswd | cut -d: -f1)
    fi

    # Method 3: First non-root home directory
    if [[ -z "$user" ]]; then
        for home_dir in /home/*/; do
            local candidate
            candidate=$(basename "$home_dir")
            if [[ "$candidate" != "lost+found" ]]; then
                user="$candidate"
                break
            fi
        done
    fi

    echo "$user"
}

# ==============================================================================
# Setup State Detection
# ==============================================================================

_check_existing_setup() {
    local score=0
    local total=7

    command_exists borg && (( score++ ))
    [[ -f "$SSH_KEY" ]] && (( score++ ))
    [[ -f "$PASSPHRASE_FILE" ]] && (( score++ ))
    [[ -f "$CONF_FILE" ]] && (( score++ ))
    [[ -f "$BACKUP_SCRIPT" ]] && (( score++ ))
    [[ -f "$SERVICE_FILE" ]] && (( score++ ))
    systemctl is-active --quiet swizzin-backup.timer 2>/dev/null && (( score++ ))

    if (( score == 0 )); then
        echo "none"
    elif (( score == total )); then
        echo "complete"
    else
        echo "partial"
    fi
}

# ==============================================================================
# Step 1: Install borgbackup
# ==============================================================================

_install_borgbackup() {
    echo_step 1 "$TOTAL_STEPS" "Install borgbackup"

    if command_exists borg; then
        local version
        version=$(borg --version 2>/dev/null | head -1)
        echo_success "borgbackup already installed ($version)"
        return 0
    fi

    echo_progress_start "Installing borgbackup"
    if apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq borgbackup >/dev/null 2>&1; then
        local version
        version=$(borg --version 2>/dev/null | head -1)
        echo_progress_done "borgbackup installed ($version)"
    else
        echo_progress_fail "Failed to install borgbackup"
        echo_error "Try manually: apt-get update && apt-get install -y borgbackup"
        exit 1
    fi
}

# ==============================================================================
# Step 2: SSH key setup
# ==============================================================================

_setup_ssh_key() {
    echo_step 2 "$TOTAL_STEPS" "SSH key setup"

    # Handle existing key
    if [[ -f "$SSH_KEY" ]]; then
        local fingerprint
        fingerprint=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')
        echo_info "Existing SSH key found: $SSH_KEY"
        echo_info "Fingerprint: $fingerprint"

        if ! ask "Reuse this key?" Y; then
            echo_progress_start "Generating new SSH key"
            rm -f "$SSH_KEY" "${SSH_KEY}.pub"
            ssh-keygen -t ed25519 -f "$SSH_KEY" -C "backup@$(hostname)" -N "" >/dev/null 2>&1
            echo_progress_done "New SSH key generated"
        else
            echo_success "Reusing existing SSH key"
        fi
    else
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        echo_progress_start "Generating SSH key"
        ssh-keygen -t ed25519 -f "$SSH_KEY" -C "backup@$(hostname)" -N "" >/dev/null 2>&1
        echo_progress_done "SSH key generated at $SSH_KEY"
    fi

    # Prompt for remote server credentials
    echo ""
    echo_info "Enter your backup server details"
    echo_info "Examples: Hetzner Storage Box, Rsync.net, BorgBase, self-hosted NAS/VPS"
    echo ""
    REMOTE_USER=$(prompt_value "SSH username")
    REMOTE_HOST=$(prompt_value "SSH hostname")
    REMOTE_PORT=$(prompt_value "SSH port" "22")

    if [[ -z "$REMOTE_USER" || -z "$REMOTE_HOST" ]]; then
        echo_error "Username and hostname are required"
        exit 1
    fi

    echo_info "Target: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"

    # Show public key for manual installation
    echo ""
    echo_info "Add this public key to your backup server's authorized_keys:"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""

    # Try automatic key installation (works for Hetzner Storage Box)
    if ask "Attempt automatic key installation? (works for Hetzner Storage Box)" N; then
        echo_info "You will be prompted for your server password"
        if cat "${SSH_KEY}.pub" | ssh -p"${REMOTE_PORT}" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" install-ssh-key 2>/dev/null; then
            echo_success "SSH key installed automatically"
        else
            echo_warn "Automatic install failed. Please add the key manually."
        fi
    fi

    # Test connection
    echo ""
    if ask "Test SSH connection now?" Y; then
        echo_progress_start "Testing SSH connection"
        if ssh -p"${REMOTE_PORT}" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" ls >/dev/null 2>&1; then
            echo_progress_done "SSH connection successful"
        else
            echo_progress_fail "SSH connection test failed"
            echo_warn "Ensure the public key is added to the server's authorized_keys"
            if ! ask "Continue anyway?" N; then
                exit 1
            fi
        fi
    fi
}

# ==============================================================================
# Step 3: Generate passphrase
# ==============================================================================

_generate_passphrase() {
    echo_step 3 "$TOTAL_STEPS" "Generate encryption passphrase"

    if [[ -f "$PASSPHRASE_FILE" ]]; then
        echo_info "Existing passphrase found: $PASSPHRASE_FILE"

        if ask "Keep existing passphrase?" Y; then
            echo_success "Keeping existing passphrase"
        else
            echo_progress_start "Generating new passphrase"
            openssl rand -base64 32 > "$PASSPHRASE_FILE"
            chmod 600 "$PASSPHRASE_FILE"
            echo_progress_done "New passphrase generated"
        fi
    else
        echo_progress_start "Generating passphrase"
        openssl rand -base64 32 > "$PASSPHRASE_FILE"
        chmod 600 "$PASSPHRASE_FILE"
        echo_progress_done "Passphrase generated at $PASSPHRASE_FILE"
    fi

    echo ""
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║  CRITICAL: Save this passphrase in a password manager NOW!  ║${NC}"
    echo -e "${BOLD}${RED}║  Without it, your backups are UNRECOVERABLE.                ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Passphrase: ${BOLD}$(cat "$PASSPHRASE_FILE")${NC}"
    echo ""

    while true; do
        if ask "I have saved the passphrase externally" N; then
            break
        fi
        echo_warn "Please save the passphrase before continuing!"
    done
}

# ==============================================================================
# Step 4: Initialize borg repository
# ==============================================================================

_init_repository() {
    echo_step 4 "$TOTAL_STEPS" "Initialize borg repository"

    local default_path="./backups/mediaserver"
    echo_info "Repository path on remote server (relative to home, or absolute)"
    local repo_path
    repo_path=$(prompt_value "Repo path" "$default_path")

    BORG_REPO_URL="ssh://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${repo_path}"
    echo_info "Repository URL: $BORG_REPO_URL"

    # Prompt for remote borg path
    echo ""
    echo_info "Remote borg binary (adjust for your server)"
    echo_info "  Hetzner Storage Box: borg-1.4"
    echo_info "  Rsync.net: borg1"
    echo_info "  Self-hosted: borg (or full path)"
    local borg_remote
    borg_remote=$(prompt_value "Remote borg path" "borg")

    export BORG_RSH="ssh -p${REMOTE_PORT} -i $SSH_KEY -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
    export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"
    export BORG_REMOTE_PATH="$borg_remote"

    # Create parent directory on remote (borg init won't create it)
    local parent_path
    parent_path=$(dirname "$repo_path")
    if [[ "$parent_path" != "." && "$parent_path" != "/" ]]; then
        echo_progress_start "Creating remote directory: $parent_path"
        if ssh -p"${REMOTE_PORT}" -i "$SSH_KEY" -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${parent_path}" 2>/dev/null; then
            echo_progress_done "Remote directory created"
        else
            echo_progress_fail "Failed to create remote directory"
            echo_warn "You may need to create it manually: ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} mkdir -p ${parent_path}"
        fi
    fi

    echo_progress_start "Initializing borg repository"

    local init_output
    local init_rc=0
    init_output=$(borg init \
        --encryption=repokey-blake2 \
        --remote-path="$borg_remote" \
        "$BORG_REPO_URL" 2>&1) || init_rc=$?

    if (( init_rc == 0 )); then
        echo_progress_done "Repository initialized"
    elif (( init_rc == 2 )); then
        if echo "$init_output" | grep -qi "repository already exists\|already been initialized"; then
            echo_progress_done "Repository already initialized (reusing)"
        else
            echo_progress_fail "Failed to initialize repository (exit code: 2)"
            echo "$init_output" | tail -10
            exit 1
        fi
    else
        echo_progress_fail "Failed to initialize repository (exit code: $init_rc)"
        echo "$init_output" | tail -10
        exit 1
    fi
}

# ==============================================================================
# Step 5: Export encryption key
# ==============================================================================

_export_key() {
    echo_step 5 "$TOTAL_STEPS" "Export encryption key"

    export BORG_RSH="ssh -i $SSH_KEY -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
    export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"

    echo_progress_start "Exporting encryption key"

    if borg key export "$BORG_REPO_URL" "$KEY_EXPORT" 2>/dev/null; then
        chmod 600 "$KEY_EXPORT"
        echo_progress_done "Key exported to $KEY_EXPORT"
    else
        echo_progress_fail "Failed to export key"
        echo_warn "You can export manually later: borg key export <repo> $KEY_EXPORT"
    fi

    echo ""
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║  CRITICAL: Save this key in a password manager too!         ║${NC}"
    echo -e "${BOLD}${RED}║  Without BOTH key + passphrase, backups are unrecoverable.  ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -f "$KEY_EXPORT" ]]; then
        cat "$KEY_EXPORT"
        echo ""
    fi

    while true; do
        if ask "I have saved the encryption key externally" N; then
            break
        fi
        echo_warn "Please save the encryption key before continuing!"
    done

    # Auto-delete key export from disk after user confirms they saved it
    if [[ -f "$KEY_EXPORT" ]]; then
        rm -f "$KEY_EXPORT"
        echo_success "Key export file deleted from disk (security measure)"
    fi
}

# ==============================================================================
# Step 6: Generate configuration
# ==============================================================================

_generate_config() {
    echo_step 6 "$TOTAL_STEPS" "Generate configuration"

    # Handle existing config
    if [[ -f "$CONF_FILE" ]]; then
        echo_warn "Configuration already exists: $CONF_FILE"
        if ask "Keep existing configuration?" Y; then
            echo_success "Keeping existing configuration"
            return 0
        fi
        echo_info "Overwriting configuration"
    fi

    # Auto-detect Swizzin user
    local detected_user
    detected_user=$(_detect_swizzin_user)
    echo_info "Detected Swizzin user: ${detected_user:-<none>}"
    local swizzin_user
    swizzin_user=$(prompt_value "Swizzin username" "$detected_user")

    if [[ -z "$swizzin_user" ]]; then
        echo_error "Swizzin username is required"
        exit 1
    fi

    # Auto-detect Zurg
    local has_zurg=false
    if [[ -d "/home/${swizzin_user}/.config/zurg" ]]; then
        has_zurg=true
        echo_success "Zurg detected: /home/${swizzin_user}/.config/zurg"
    else
        echo_info "Zurg not detected (skipping ZURG_DIR)"
    fi

    # Prompt for notifications
    echo ""
    echo_info "Configure notifications (all optional, all fire simultaneously)"
    echo ""

    local hc_uuid="" discord_webhook="" pushover_user="" pushover_token=""
    local notifiarr_key="" email_to=""

    if ask "Configure Healthchecks.io?" N; then
        hc_uuid=$(prompt_value "  Healthchecks.io UUID")
    fi

    if ask "Configure Discord webhook?" N; then
        discord_webhook=$(prompt_value "  Discord webhook URL")
    fi

    if ask "Configure Pushover?" N; then
        pushover_user=$(prompt_value "  Pushover user key")
        pushover_token=$(prompt_value "  Pushover app token")
    fi

    if ask "Configure Notifiarr?" N; then
        notifiarr_key=$(prompt_value "  Notifiarr API key")
    fi

    if ask "Configure email notifications?" N; then
        email_to=$(prompt_value "  Email address")
    fi

    # Precompute ZURG_DIR value (single quotes preserve literal ${SWIZZIN_USER})
    # When written to the heredoc, ${zurg_dir_value} expands once and the inner
    # ${SWIZZIN_USER} remains literal in the output file.
    local zurg_dir_value=""
    if [[ "$has_zurg" == true ]]; then
        zurg_dir_value='/home/${SWIZZIN_USER}/.config/zurg'
    fi

    # Write config
    cat > "$CONF_FILE" <<CONF
#===============================================================================
# Swizzin Backup Configuration (BorgBackup)
# Location: /etc/swizzin-backup.conf
#
# This file is sourced by swizzin-backup.sh and swizzin-restore.sh
# All BORG_* variables are exported automatically by the scripts
#===============================================================================

#===============================================================================
# BORG REPOSITORY (REQUIRED)
#===============================================================================

# Remote borg repository (any SSH-accessible borg server)
BORG_REPO="${BORG_REPO_URL}"

# Passphrase handling
BORG_PASSCOMMAND="cat /root/.swizzin-backup-passphrase"

# SSH configuration
BORG_RSH="ssh -p${REMOTE_PORT} -i /root/.ssh/id_backup -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

# Remote borg version (adjust for your server)
BORG_REMOTE_PATH="${BORG_REMOTE_PATH:-borg}"

#===============================================================================
# SWIZZIN (REQUIRED)
#===============================================================================

# Primary Swizzin user
SWIZZIN_USER="${swizzin_user}"

# Zurg installation directory (paid zurg)
ZURG_DIR="${zurg_dir_value}"

#===============================================================================
# HEALTHCHECKS (OPTIONAL)
# Ping healthchecks.io on start/success/failure
#===============================================================================

HC_UUID="${hc_uuid}"

#===============================================================================
# NOTIFICATIONS (OPTIONAL)
# All configured providers fire simultaneously
#===============================================================================

# Discord webhook URL
DISCORD_WEBHOOK="${discord_webhook}"

# Pushover (both required)
PUSHOVER_USER="${pushover_user}"
PUSHOVER_TOKEN="${pushover_token}"

# Notifiarr passthrough API key
NOTIFIARR_API_KEY="${notifiarr_key}"

# Email (requires sendmail or mail command)
EMAIL_TO="${email_to}"

#===============================================================================
# RETENTION (OPTIONAL — defaults shown)
#===============================================================================

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=2

#===============================================================================
# PATHS (OPTIONAL — defaults shown)
#===============================================================================

# LOCKFILE="/var/run/swizzin-backup.lock"
# LOGFILE="/var/log/swizzin-backup.log"
# EXCLUDES_FILE="/etc/swizzin-excludes.txt"
# STOPPED_SERVICES_FILE="/var/run/swizzin-stopped-services.txt"
CONF

    chmod 600 "$CONF_FILE"
    echo_success "Configuration written to $CONF_FILE"
}

# ==============================================================================
# Step 7: Deploy files
# ==============================================================================

_deploy_files() {
    echo_step 7 "$TOTAL_STEPS" "Deploy files"

    local script_dir
    script_dir=$(_detect_script_dir)

    # Define source → target mappings
    local -A file_map=(
        ["swizzin-backup.sh"]="$BACKUP_SCRIPT"
        ["swizzin-restore.sh"]="$RESTORE_SCRIPT"
        ["swizzin-excludes.txt"]="$EXCLUDES_TARGET"
        ["swizzin-backup.service"]="$SERVICE_FILE"
        ["swizzin-backup.timer"]="$TIMER_FILE"
        ["swizzin-backup-verify.service"]="$VERIFY_SERVICE_FILE"
        ["swizzin-backup-verify.timer"]="$VERIFY_TIMER_FILE"
        ["swizzin-backup-logrotate"]="$LOGROTATE_FILE"
    )

    local -A mode_map=(
        ["swizzin-backup.sh"]="755"
        ["swizzin-restore.sh"]="755"
        ["swizzin-excludes.txt"]="644"
        ["swizzin-backup.service"]="644"
        ["swizzin-backup.timer"]="644"
        ["swizzin-backup-verify.service"]="644"
        ["swizzin-backup-verify.timer"]="644"
        ["swizzin-backup-logrotate"]="644"
    )

    local failed=0

    for source_name in "${!file_map[@]}"; do
        local source_path="${script_dir}/${source_name}"
        local target_path="${file_map[$source_name]}"
        local mode="${mode_map[$source_name]}"

        if [[ ! -f "$source_path" ]]; then
            echo_error "Source file not found: $source_path"
            (( failed++ )) || true
            continue
        fi

        mkdir -p "$(dirname "$target_path")"
        cp "$source_path" "$target_path"
        chmod "$mode" "$target_path"
        echo_success "Deployed: $target_path"
    done

    # Deploy shared notifications library
    local notif_source="${script_dir}/../lib/notifications.sh"
    if [[ -f "$notif_source" ]]; then
        mkdir -p "$(dirname "$NOTIFICATIONS_LIB")"
        cp "$notif_source" "$NOTIFICATIONS_LIB"
        chmod 644 "$NOTIFICATIONS_LIB"
        echo_success "Deployed: $NOTIFICATIONS_LIB"
    else
        echo_error "Source file not found: $notif_source"
        (( failed++ )) || true
    fi

    if (( failed > 0 )); then
        echo_error "$failed file(s) failed to deploy"
        exit 1
    fi

    echo_progress_start "Reloading systemd"
    systemctl daemon-reload
    echo_progress_done "systemd reloaded"
}

# ==============================================================================
# Step 8: Verify
# ==============================================================================

_verify_setup() {
    echo_step 8 "$TOTAL_STEPS" "Verify setup"

    echo_progress_start "Checking service discovery"
    if "$BACKUP_SCRIPT" --services >/dev/null 2>&1; then
        echo_progress_done "Service discovery works"
        echo ""
        "$BACKUP_SCRIPT" --services
    else
        echo_progress_fail "Service discovery check failed"
        echo_warn "Check $CONF_FILE and try: borg-backup.sh --services"
    fi

    echo ""
    if ask "Run a dry-run backup to verify paths?" N; then
        echo_info "Running dry-run..."
        echo ""
        "$BACKUP_SCRIPT" --dry-run || true
    fi
}

# ==============================================================================
# Step 9: Enable timer
# ==============================================================================

_enable_timer() {
    echo_step 9 "$TOTAL_STEPS" "Enable daily timer"

    echo_progress_start "Enabling swizzin-backup.timer"
    systemctl enable --now swizzin-backup.timer >/dev/null 2>&1
    echo_progress_done "Backup timer enabled"

    echo_progress_start "Enabling swizzin-backup-verify.timer"
    systemctl enable --now swizzin-backup-verify.timer >/dev/null 2>&1
    echo_progress_done "Verify timer enabled (weekly)"

    echo ""
    echo_info "Scheduled times:"
    systemctl list-timers swizzin-backup.timer swizzin-backup-verify.timer --no-pager 2>/dev/null || true
}

# ==============================================================================
# Step 10: Optional first backup
# ==============================================================================

_offer_first_backup() {
    echo_step 10 "$TOTAL_STEPS" "First backup"

    if ask "Run a full backup now?" N; then
        echo_info "Starting backup... (this may take a while for the first run)"
        echo ""
        "$BACKUP_SCRIPT" || true
    else
        echo_info "Skipping first backup. The timer will run it at 4 AM."
    fi
}

# ==============================================================================
# Summary
# ==============================================================================

_show_summary() {
    echo_header "Setup Complete"

    echo -e "${BOLD}Deployed files:${NC}"
    echo "  Scripts:    $BACKUP_SCRIPT"
    echo "              $RESTORE_SCRIPT"
    echo "  Config:     $CONF_FILE"
    echo "  Excludes:   $EXCLUDES_TARGET"
    echo "  Service:    $SERVICE_FILE"
    echo "  Timer:      $TIMER_FILE"
    echo "  Logrotate:  $LOGROTATE_FILE"
    echo ""
    echo -e "${BOLD}Credentials:${NC}"
    echo "  SSH key:        $SSH_KEY"
    echo "  Passphrase:     $PASSPHRASE_FILE"
    echo "  Key export:     (deleted after display — saved externally)"
    echo ""
    echo -e "${BOLD}Repository:${NC}"
    echo "  URL: ${BORG_REPO_URL:-<not set>}"
    echo ""
    echo -e "${BOLD}Schedule:${NC}"
    echo "  Backup:  Daily at 4:00 AM (±30 min jitter)"
    echo "  Verify:  Weekly on Sunday at 4:00 AM (±30 min jitter)"
    echo ""
    echo -e "${BOLD}Quick commands:${NC}"
    echo "  swizzin-backup.sh              # Run backup"
    echo "  swizzin-backup.sh --services   # List discovered services"
    echo "  swizzin-backup.sh --list       # List archives"
    echo "  swizzin-restore.sh             # Interactive restore"
    echo "  journalctl -u swizzin-backup   # View logs"
    echo ""
    echo -e "${BOLD}${RED}Reminders:${NC}"
    echo "  1. Save passphrase + key export in a password manager"
    echo "  2. Test restore periodically: swizzin-restore.sh --mount"
    echo "  3. Consider append-only mode for ransomware protection"
    echo "     (see README.md > Security > Append-only mode)"
}

# ==============================================================================
# --status
# ==============================================================================

_show_status() {
    echo_header "Swizzin Backup Setup Status"

    # borgbackup
    if command_exists borg; then
        local version
        version=$(borg --version 2>/dev/null | head -1)
        echo -e "${GREEN}[OK]${NC}      borgbackup installed ($version)"
    else
        echo -e "${RED}[MISSING]${NC} borgbackup not installed"
    fi

    # SSH key
    if [[ -f "$SSH_KEY" ]]; then
        local fp
        fp=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')
        echo -e "${GREEN}[OK]${NC}      SSH key exists ($SSH_KEY) [$fp]"
    else
        echo -e "${RED}[MISSING]${NC} SSH key ($SSH_KEY)"
    fi

    # Passphrase
    if [[ -f "$PASSPHRASE_FILE" ]]; then
        echo -e "${GREEN}[OK]${NC}      Passphrase exists ($PASSPHRASE_FILE)"
    else
        echo -e "${RED}[MISSING]${NC} Passphrase ($PASSPHRASE_FILE)"
    fi

    # Repository - check via config
    if [[ -f "$CONF_FILE" ]]; then
        local repo_url
        repo_url=$(grep -oP '^BORG_REPO="\K[^"]+' "$CONF_FILE" 2>/dev/null || true)
        if [[ -n "$repo_url" ]]; then
            echo -e "${GREEN}[OK]${NC}      Repository configured ($repo_url)"
        else
            echo -e "${YELLOW}[WARN]${NC}    Repository URL not found in config"
        fi
    else
        echo -e "${RED}[MISSING]${NC} Repository (no config file)"
    fi

    # Key export (auto-deleted after setup — should be saved externally)
    if [[ -f "$KEY_EXPORT" ]]; then
        echo -e "${YELLOW}[WARN]${NC}    Key export file still on disk ($KEY_EXPORT) — save externally and delete"
    else
        echo -e "${GREEN}[OK]${NC}      Key export not on disk (saved externally)"
    fi

    # Configuration
    if [[ -f "$CONF_FILE" ]]; then
        echo -e "${GREEN}[OK]${NC}      Configuration ($CONF_FILE)"
    else
        echo -e "${RED}[MISSING]${NC} Configuration ($CONF_FILE)"
    fi

    # Scripts
    if [[ -f "$BACKUP_SCRIPT" && -f "$RESTORE_SCRIPT" ]]; then
        echo -e "${GREEN}[OK]${NC}      Scripts deployed ($BACKUP_SCRIPT)"
    elif [[ -f "$BACKUP_SCRIPT" || -f "$RESTORE_SCRIPT" ]]; then
        echo -e "${YELLOW}[WARN]${NC}    Scripts partially deployed"
    else
        echo -e "${RED}[MISSING]${NC} Scripts ($BACKUP_SCRIPT)"
    fi

    # Excludes
    if [[ -f "$EXCLUDES_TARGET" ]]; then
        echo -e "${GREEN}[OK]${NC}      Excludes file ($EXCLUDES_TARGET)"
    else
        echo -e "${RED}[MISSING]${NC} Excludes file ($EXCLUDES_TARGET)"
    fi

    # Systemd units
    if [[ -f "$SERVICE_FILE" && -f "$TIMER_FILE" ]]; then
        echo -e "${GREEN}[OK]${NC}      Systemd units deployed"
    else
        echo -e "${RED}[MISSING]${NC} Systemd units"
    fi

    # Timer active
    if systemctl is-active --quiet swizzin-backup.timer 2>/dev/null; then
        local next
        next=$(systemctl list-timers swizzin-backup.timer --no-pager 2>/dev/null | grep swizzin | awk '{print $1, $2, $3}')
        echo -e "${GREEN}[OK]${NC}      Timer active (next: ${next:-unknown})"
    elif systemctl is-enabled --quiet swizzin-backup.timer 2>/dev/null; then
        echo -e "${YELLOW}[WARN]${NC}    Timer enabled but not active"
    else
        echo -e "${RED}[MISSING]${NC} Timer not enabled"
    fi

    # Logrotate
    if [[ -f "$LOGROTATE_FILE" ]]; then
        echo -e "${GREEN}[OK]${NC}      Logrotate configured"
    else
        echo -e "${RED}[MISSING]${NC} Logrotate ($LOGROTATE_FILE)"
    fi

    # Notifications
    if [[ -f "$CONF_FILE" ]]; then
        local notif_count=0
        grep -qP '^DISCORD_WEBHOOK=".+"' "$CONF_FILE" 2>/dev/null && (( notif_count++ ))
        grep -qP '^PUSHOVER_USER=".+"' "$CONF_FILE" 2>/dev/null && (( notif_count++ ))
        grep -qP '^NOTIFIARR_API_KEY=".+"' "$CONF_FILE" 2>/dev/null && (( notif_count++ ))
        grep -qP '^EMAIL_TO=".+"' "$CONF_FILE" 2>/dev/null && (( notif_count++ ))
        grep -qP '^HC_UUID=".+"' "$CONF_FILE" 2>/dev/null && (( notif_count++ ))

        if (( notif_count > 0 )); then
            echo -e "${GREEN}[OK]${NC}      Notifications ($notif_count provider(s) configured)"
        else
            echo -e "${YELLOW}[WARN]${NC}    No notifications configured"
        fi
    fi

    echo ""
}

# ==============================================================================
# --remove
# ==============================================================================

_remove() {
    echo_header "Remove Swizzin Backup Setup"

    echo_warn "This will remove all deployed files from this server."
    echo_warn "The remote borg repository will NOT be deleted."
    echo ""

    if ! ask "Proceed with removal?" N; then
        echo_info "Removal cancelled"
        exit 0
    fi

    # Stop and disable timers
    echo_progress_start "Stopping timers"
    systemctl stop swizzin-backup.timer 2>/dev/null || true
    systemctl disable swizzin-backup.timer 2>/dev/null || true
    systemctl stop swizzin-backup-verify.timer 2>/dev/null || true
    systemctl disable swizzin-backup-verify.timer 2>/dev/null || true
    echo_progress_done "Timers stopped and disabled"

    # Remove deployed files
    local files_to_remove=(
        "$BACKUP_SCRIPT"
        "$RESTORE_SCRIPT"
        "$EXCLUDES_TARGET"
        "$SERVICE_FILE"
        "$TIMER_FILE"
        "$VERIFY_SERVICE_FILE"
        "$VERIFY_TIMER_FILE"
        "$LOGROTATE_FILE"
        "$NOTIFICATIONS_LIB"
    )

    for f in "${files_to_remove[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            echo_success "Removed: $f"
        fi
    done

    # Clean up empty parent directory left by notifications library
    rmdir "$(dirname "$NOTIFICATIONS_LIB")" 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true
    echo_success "systemd reloaded"

    # Optionally remove credentials
    echo ""
    if ask "Remove configuration and credentials?" N; then
        [[ -f "$CONF_FILE" ]] && rm -f "$CONF_FILE" && echo_success "Removed: $CONF_FILE"
        [[ -f "$PASSPHRASE_FILE" ]] && rm -f "$PASSPHRASE_FILE" && echo_success "Removed: $PASSPHRASE_FILE"
        [[ -f "$KEY_EXPORT" ]] && rm -f "$KEY_EXPORT" && echo_success "Removed: $KEY_EXPORT"
    else
        echo_info "Credentials kept"
    fi

    # Optionally remove SSH key
    if ask "Remove SSH key ($SSH_KEY)?" N; then
        rm -f "$SSH_KEY" "${SSH_KEY}.pub"
        echo_success "Removed SSH key"
    else
        echo_info "SSH key kept"
    fi

    echo ""
    echo_warn "Remote repository was NOT deleted."
    echo_info "To delete the remote repo, use borg on the Storage Box directly."
    echo ""
    echo_success "Removal complete"
}

# ==============================================================================
# --help
# ==============================================================================

_show_help() {
    cat <<'EOF'
Swizzin Backup Setup Wizard (BorgBackup)

Usage:
  bash swizzin-backup-install.sh              Interactive setup wizard
  bash swizzin-backup-install.sh --status     Show current setup status
  bash swizzin-backup-install.sh --remove     Remove deployed files (not remote repo)
  bash swizzin-backup-install.sh --help       Show this help

Supported backup targets:
  - Hetzner Storage Box
  - Rsync.net
  - BorgBase
  - Self-hosted (NAS, VPS, dedicated server)

The setup wizard walks through 10 steps:
  1. Install borgbackup
  2. SSH key setup (generate + add to remote server)
  3. Generate encryption passphrase
  4. Initialize borg repository
  5. Export encryption key
  6. Generate configuration
  7. Deploy scripts, configs, and systemd units
  8. Verify setup
  9. Enable daily timer
 10. Optional first backup

The wizard is idempotent — safe to re-run. Existing components are
detected and you're asked whether to reuse or regenerate them.

Files deployed:
  /usr/local/bin/swizzin-backup.sh       Backup script
  /usr/local/bin/swizzin-restore.sh      Restore script
  /etc/swizzin-backup.conf               Configuration
  /etc/swizzin-excludes.txt              Exclusion patterns
  /etc/systemd/system/swizzin-backup.*   Systemd service + timer
  /etc/logrotate.d/swizzin-backup        Log rotation

Credentials stored:
  /root/.ssh/id_backup                   SSH key pair
  /root/.swizzin-backup-passphrase       Encryption passphrase
  /root/swizzin-backup-key-export.txt    Encryption key export
EOF
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    case "${1:-}" in
        --status)
            _show_status
            exit 0
            ;;
        --remove)
            require_root
            _remove
            exit 0
            ;;
        --help|-h)
            _show_help
            exit 0
            ;;
        "")
            # Interactive setup — continue below
            ;;
        *)
            echo_error "Unknown option: $1"
            echo "Run with --help for usage"
            exit 1
            ;;
    esac

    require_root

    echo_header "Swizzin Backup Setup Wizard"

    # Check existing setup
    local state
    state=$(_check_existing_setup)

    if [[ "$state" == "complete" ]]; then
        echo_warn "Setup appears complete. All components are already in place."
        if ! ask "Re-run setup anyway?" N; then
            echo_info "Run with --status to view current state"
            exit 0
        fi
    elif [[ "$state" == "partial" ]]; then
        echo_info "Partial setup detected. The wizard will pick up where applicable."
    fi

    # Run all steps
    _install_borgbackup
    _setup_ssh_key
    _generate_passphrase
    _init_repository
    _export_key
    _generate_config
    _deploy_files
    _verify_setup
    _enable_timer
    _offer_first_backup
    _show_summary
}

main "$@"
