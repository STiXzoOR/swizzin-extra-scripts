#!/bin/bash
# restore.sh - Restore default configurations
# Part of swizzin-scripts bootstrap

BACKUP_DIR="/opt/swizzin-extras/bootstrap-backups"

# ==============================================================================
# SSH Restore
# ==============================================================================

restore_ssh() {
    echo_header "Restoring SSH Defaults"

    echo_progress_start "Removing SSH hardening config"

    # Remove hardening config
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf

    # Restore backup if exists
    local backup_file
    backup_file=$(find "$BACKUP_DIR/ssh" -name "sshd_config*.bak" -type f 2>/dev/null | sort -r | head -1)

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo_info "Restoring from backup: $backup_file"
        cp "$backup_file" /etc/ssh/sshd_config
    fi

    echo_progress_done "SSH hardening config removed"

    # Validate and restart
    if sshd -t &>/dev/null; then
        echo_progress_start "Restarting SSH service"
        # Reload systemd to pick up config changes
        systemctl daemon-reload

        # Ubuntu 24.04+ uses socket activation, earlier versions use service only
        if systemctl list-units --type=socket | grep -q "ssh.socket"; then
            systemctl restart ssh.socket
            systemctl restart ssh.service
        elif systemctl list-units --type=service | grep -q "ssh.service"; then
            systemctl restart ssh
        else
            systemctl restart sshd
        fi
        echo_progress_done "SSH service restarted"
    else
        echo_error "SSH config is invalid after restore!"
        exit 1
    fi

    echo_success "SSH restored to defaults (port 22, password auth may be enabled)"
    echo_warn "You may need to re-add your SSH key if password auth is disabled"
}

# ==============================================================================
# fail2ban Restore
# ==============================================================================

restore_fail2ban() {
    echo_header "Restoring fail2ban Defaults"

    echo_progress_start "Removing custom fail2ban config"

    # Remove custom jail config
    rm -f /etc/fail2ban/jail.local

    # Restore backup if exists
    local backup_file
    backup_file=$(find "$BACKUP_DIR/fail2ban" -name "jail.local*.bak" -type f 2>/dev/null | sort -r | head -1)

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo_info "Restoring from backup: $backup_file"
        cp "$backup_file" /etc/fail2ban/jail.local
    fi

    echo_progress_done "Custom fail2ban config removed"

    # Restart fail2ban
    if systemctl is-active --quiet fail2ban; then
        echo_progress_start "Restarting fail2ban"
        systemctl restart fail2ban
        echo_progress_done "fail2ban restarted"
    fi

    echo_success "fail2ban restored to defaults"
}

# ==============================================================================
# UFW Restore
# ==============================================================================

restore_ufw() {
    echo_header "Restoring UFW Defaults"

    echo_progress_start "Resetting UFW rules"

    # Reset UFW
    ufw --force reset >/dev/null 2>&1

    # Set basic defaults
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH on default port
    ufw allow 22/tcp comment 'SSH'

    # Re-enable
    ufw --force enable

    echo_progress_done "UFW reset to defaults"

    echo_success "UFW restored (SSH port 22 allowed)"
    echo_info "Current rules:"
    ufw status numbered
}

# ==============================================================================
# Sysctl/Tuning Restore
# ==============================================================================

restore_tuning() {
    echo_header "Restoring Kernel Tuning Defaults"

    echo_progress_start "Removing custom sysctl config"

    # Remove custom configs
    rm -f /etc/sysctl.d/99-streaming.conf
    rm -f /etc/sysctl.d/99-streaming-optimizer.conf
    rm -f /etc/security/limits.d/99-streaming.conf
    rm -f /etc/systemd/system.conf.d/99-limits.conf
    rm -f /etc/systemd/user.conf.d/99-limits.conf
    rm -f /etc/modules-load.d/bbr.conf
    rm -f /etc/modprobe.d/fuse.conf

    echo_progress_done "Custom tuning configs removed"

    # Restore backup if exists
    local backup_file
    backup_file=$(find "$BACKUP_DIR/sysctl" -name "sysctl.conf*.bak" -type f 2>/dev/null | sort -r | head -1)

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo_info "Restoring from backup: $backup_file"
        cp "$backup_file" /etc/sysctl.conf
    fi

    backup_file=$(find "$BACKUP_DIR/limits" -name "limits.conf*.bak" -type f 2>/dev/null | sort -r | head -1)

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo_info "Restoring limits from backup: $backup_file"
        cp "$backup_file" /etc/security/limits.conf
    fi

    # Reload sysctl
    echo_progress_start "Reloading sysctl"
    sysctl --system &>/dev/null
    echo_progress_done "Sysctl reloaded"

    # Reload systemd
    systemctl daemon-reload

    echo_success "Kernel tuning restored to defaults"
    echo_info "Some settings may require a reboot to fully reset"
}

# ==============================================================================
# Unattended Upgrades Restore
# ==============================================================================

restore_unattended_upgrades() {
    echo_header "Restoring Unattended Upgrades Defaults"

    echo_progress_start "Removing custom unattended-upgrades config"

    # Restore backup if exists
    local backup_file
    backup_file=$(find "$BACKUP_DIR/apt" -name "50unattended-upgrades*.bak" -type f 2>/dev/null | sort -r | head -1)

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo_info "Restoring from backup: $backup_file"
        cp "$backup_file" /etc/apt/apt.conf.d/50unattended-upgrades
    else
        # Remove custom config, package defaults will be used
        rm -f /etc/apt/apt.conf.d/50unattended-upgrades
    fi

    # Remove custom auto-upgrades config
    rm -f /etc/apt/apt.conf.d/20auto-upgrades

    echo_progress_done "Custom unattended-upgrades config removed"

    echo_success "Unattended upgrades restored to package defaults"
}

# ==============================================================================
# Full Restore
# ==============================================================================

restore_all() {
    echo_header "Full Restore"

    echo_warn "This will restore ALL bootstrap configurations to defaults!"
    echo_info "This includes: SSH, fail2ban, UFW, kernel tuning, unattended-upgrades"
    echo ""

    if ! ask "Are you sure you want to restore all settings?" N; then
        echo_info "Restore cancelled"
        return 0
    fi

    restore_ssh
    restore_fail2ban
    restore_ufw
    restore_tuning
    restore_unattended_upgrades

    # Remove bootstrap marker
    rm -f /opt/swizzin-extras/bootstrap.done
    rm -f /opt/swizzin-extras/bootstrap.conf

    echo ""
    echo_success "All bootstrap configurations restored to defaults"
    echo_info "The server is now in a pre-bootstrap state"
    echo_warn "You may need to reboot for all changes to take effect"
}

# ==============================================================================
# List Backups
# ==============================================================================

list_backups() {
    echo_header "Available Backups"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo_info "No backups found"
        return 0
    fi

    echo "Backup directory: $BACKUP_DIR"
    echo ""

    for category in ssh fail2ban ufw sysctl limits apt; do
        local dir="$BACKUP_DIR/$category"
        if [[ -d "$dir" ]]; then
            echo -e "${BOLD}$category:${NC}"
            find "$dir" -name "*.bak" -type f -exec ls -lh {} \; 2>/dev/null | awk '{print "  " $9 " (" $5 ", " $6 " " $7 ")"}'
            echo ""
        fi
    done
}

# ==============================================================================
# Clean Backups
# ==============================================================================

clean_backups() {
    echo_header "Clean Backups"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo_info "No backups to clean"
        return 0
    fi

    local size
    size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo_info "Backup directory size: $size"

    if ask "Remove all backups?" N; then
        rm -rf "$BACKUP_DIR"
        echo_success "Backups removed"
    else
        echo_info "Backups kept"
    fi
}
