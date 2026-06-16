#!/bin/bash
# notifications.sh - Pushover and other notification setup
# Part of swizzin-scripts bootstrap

# ==============================================================================
# Pushover Notifications
# ==============================================================================

# Global Pushover credentials (set during config collection)
PUSHOVER_USER="${PUSHOVER_USER:-}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"

send_pushover() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"  # -2 (lowest) to 2 (emergency)
    local sound="${4:-pushover}"

    # Skip if credentials not set
    if [[ -z "$PUSHOVER_USER" || -z "$PUSHOVER_TOKEN" ]]; then
        echo_debug "Pushover credentials not set, skipping notification"
        return 0
    fi

    curl -sf -X POST https://api.pushover.net/1/messages.json \
        -d "token=$PUSHOVER_TOKEN" \
        -d "user=$PUSHOVER_USER" \
        -d "title=$title" \
        -d "message=$message" \
        -d "priority=$priority" \
        -d "sound=$sound" \
        >/dev/null 2>&1

    local result=$?
    if [[ $result -eq 0 ]]; then
        echo_debug "Pushover notification sent: $title"
    else
        echo_debug "Pushover notification failed"
    fi
    return $result
}

test_pushover() {
    echo_progress_start "Testing Pushover notification"

    if [[ -z "$PUSHOVER_USER" || -z "$PUSHOVER_TOKEN" ]]; then
        echo_progress_fail "Pushover credentials not configured"
        return 1
    fi

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    if send_pushover "Bootstrap Test" "Notification test from $hostname" 0 "cosmic"; then
        echo_progress_done "Test notification sent"
        return 0
    else
        echo_progress_fail "Failed to send test notification"
        return 1
    fi
}

configure_pushover() {
    echo_header "Pushover Configuration"

    if [[ -n "$PUSHOVER_USER" && -n "$PUSHOVER_TOKEN" ]]; then
        echo_info "Pushover credentials already set"
        if ask "Test notification?" Y; then
            test_pushover
        fi
        return 0
    fi

    echo_info "Pushover is used for system notifications (reboots, updates, etc.)"
    echo_info "Get your credentials at: https://pushover.net/"
    echo ""

    if ! ask "Configure Pushover notifications?" Y; then
        echo_info "Skipping Pushover configuration"
        return 0
    fi

    # Prompt for credentials
    PUSHOVER_USER=$(prompt_value "Pushover User Key")
    PUSHOVER_TOKEN=$(prompt_value "Pushover API Token")

    if [[ -z "$PUSHOVER_USER" || -z "$PUSHOVER_TOKEN" ]]; then
        echo_warn "Pushover credentials incomplete, skipping"
        return 1
    fi

    # Test the credentials
    if test_pushover; then
        echo_success "Pushover configured successfully"

        # Export for other scripts
        export PUSHOVER_USER
        export PUSHOVER_TOKEN

        return 0
    else
        echo_error "Pushover test failed - check your credentials"
        PUSHOVER_USER=""
        PUSHOVER_TOKEN=""
        return 1
    fi
}

# ==============================================================================
# Notification Scripts
# ==============================================================================

create_notification_scripts() {
    echo_header "Creating Notification Scripts"

    local script_dir="/opt/swizzin-extras"
    mkdir -p "$script_dir"

    # Create main notification helper
    echo_progress_start "Creating notification helper"

    cat > "$script_dir/notify.sh" <<'SCRIPT'
#!/bin/bash
# Swizzin notification helper
# Usage: notify.sh <title> <message> [priority] [sound]

CONF_FILE="/opt/swizzin-extras/bootstrap.conf"

# Load config
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
fi

TITLE="${1:-Notification}"
MESSAGE="${2:-No message}"
PRIORITY="${3:-0}"
SOUND="${4:-pushover}"

# Pushover
if [[ -n "$PUSHOVER_USER" && -n "$PUSHOVER_TOKEN" ]]; then
    curl -sf -X POST https://api.pushover.net/1/messages.json \
        -d "token=$PUSHOVER_TOKEN" \
        -d "user=$PUSHOVER_USER" \
        -d "title=$TITLE" \
        -d "message=$MESSAGE" \
        -d "priority=$PRIORITY" \
        -d "sound=$SOUND" \
        >/dev/null 2>&1
fi

# Discord (if configured)
if [[ -n "$DISCORD_WEBHOOK" ]]; then
    curl -sf -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"**$TITLE**\n$MESSAGE\"}" \
        >/dev/null 2>&1
fi
SCRIPT

    chmod +x "$script_dir/notify.sh"
    echo_progress_done "Notification helper created"

    # Create reboot notification script
    echo_progress_start "Creating reboot notification script"

    cat > "$script_dir/notify-reboot.sh" <<'SCRIPT'
#!/bin/bash
# Notify on system reboot

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
UPTIME=$(uptime -p 2>/dev/null || echo "unknown")
BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo "unknown")

/opt/swizzin-extras/notify.sh \
    "Server Rebooted" \
    "Server: $HOSTNAME
Boot time: $BOOT_TIME
Uptime: $UPTIME" \
    0 \
    "cosmic"
SCRIPT

    chmod +x "$script_dir/notify-reboot.sh"
    echo_progress_done "Reboot notification script created"

    # Create apt update notification script
    echo_progress_start "Creating apt notification script"

    cat > "$script_dir/notify-updates.sh" <<'SCRIPT'
#!/bin/bash
# Notify about apt updates
# Called by apt via Dpkg::Pre-Install-Pkgs hook

HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# Count packages being updated
PACKAGE_COUNT=0
while read -r line; do
    ((PACKAGE_COUNT++))
done

if [[ $PACKAGE_COUNT -gt 0 ]]; then
    /opt/swizzin-extras/notify.sh \
        "System Updates" \
        "Server: $HOSTNAME
$PACKAGE_COUNT package(s) being updated" \
        -1 \
        "none"
fi
SCRIPT

    chmod +x "$script_dir/notify-updates.sh"
    echo_progress_done "Apt notification script created"

    echo_success "Notification scripts created"
}

# ==============================================================================
# System Integration
# ==============================================================================

setup_reboot_notification() {
    echo_progress_start "Setting up reboot notification"

    # Add cron job for reboot notification
    local cron_file="/etc/cron.d/bootstrap-notify"

    cat > "$cron_file" <<'CRON'
# Notify on system reboot
@reboot root sleep 60 && /opt/swizzin-extras/notify-reboot.sh
CRON

    chmod 644 "$cron_file"
    echo_progress_done "Reboot notification configured"
}

setup_apt_notification() {
    echo_progress_start "Setting up apt update notifications"

    # Add apt hook for update notifications
    cat > /etc/apt/apt.conf.d/99-notify <<'APT'
// Notify about package updates
Dpkg::Pre-Install-Pkgs {"/opt/swizzin-extras/notify-updates.sh";};
APT

    echo_progress_done "Apt notifications configured"
}

# ==============================================================================
# Save Configuration
# ==============================================================================

save_notification_config() {
    local conf_file="/opt/swizzin-extras/bootstrap.conf"

    echo_progress_start "Saving notification configuration"

    # Create or update config file
    cat > "$conf_file" <<EOF
# Bootstrap Configuration
# Generated: $(date)

# Pushover
PUSHOVER_USER="${PUSHOVER_USER:-}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"

# Discord (optional)
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

# Email (optional)
EMAIL_TO="${EMAIL_TO:-}"
EOF

    chmod 600 "$conf_file"
    echo_progress_done "Configuration saved to $conf_file"
}

# ==============================================================================
# Run All Notification Setup
# ==============================================================================

run_notification_setup() {
    configure_pushover
    create_notification_scripts
    setup_reboot_notification
    setup_apt_notification
    save_notification_config

    echo ""
    echo_success "Notification system configured"

    # Send completion notification
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    send_pushover \
        "Bootstrap Complete" \
        "Server $hostname has been bootstrapped successfully." \
        0 \
        "magic"
}
