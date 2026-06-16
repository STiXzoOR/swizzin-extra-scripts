#!/bin/bash
# hardening.sh - SSH, fail2ban, UFW configuration
# Part of swizzin-scripts bootstrap

# ==============================================================================
# SSH Hardening
# ==============================================================================

configure_ssh() {
    local ssh_port="${1:-22}"
    local ssh_key="$2"

    echo_header "SSH Hardening"

    # Backup original config
    backup_file "/etc/ssh/sshd_config" "/opt/swizzin-extras/bootstrap-backups/ssh"

    # Create hardening config directory
    mkdir -p /etc/ssh/sshd_config.d

    # Ensure sshd_config includes the .d directory
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config 2>/dev/null; then
        echo_progress_start "Enabling sshd_config.d includes"
        # Check if there's a commented Include line to uncomment
        if grep -q "^#Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#Include \/etc\/ssh\/sshd_config.d\/\*.conf/Include \/etc\/ssh\/sshd_config.d\/*.conf/' /etc/ssh/sshd_config
        else
            # Add Include at the beginning of the file
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        fi
        echo_progress_done "sshd_config.d includes enabled"
    fi

    echo_progress_start "Configuring SSH hardening"

    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# Bootstrap SSH Hardening Configuration
# Generated: $(date)

# Port Configuration
Port ${ssh_port}

# Authentication
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no

# Security
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable unused features
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no

# Logging
LogLevel VERBOSE
EOF

    echo_progress_done "SSH hardening config created"

    # Add SSH key if provided
    if [[ -n "$ssh_key" ]]; then
        _add_ssh_key "$ssh_key"
    fi

    # Validate SSH config before restart
    if ! sshd -t &>/dev/null; then
        echo_error "SSH configuration is invalid!"
        echo_info "Restoring original config..."
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        exit 1
    fi

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

    echo_success "SSH hardened on port $ssh_port"
    echo ""
    echo_warn "IMPORTANT: Test SSH access in a new terminal before closing this session!"
    echo_info "Connect with: ssh -p $ssh_port root@<server-ip>"
}

_add_ssh_key() {
    local key="$1"
    local auth_keys="/root/.ssh/authorized_keys"

    echo_progress_start "Adding SSH public key"

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Check if key is a file path
    if [[ -f "$key" ]]; then
        key=$(cat "$key")
    fi

    # Validate key
    if ! validate_ssh_key "$key"; then
        echo_warn "Invalid SSH key format, skipping"
        return 1
    fi

    # Add key if not already present
    if ! grep -qF "$key" "$auth_keys" 2>/dev/null; then
        echo "$key" >> "$auth_keys"
    fi

    chmod 600 "$auth_keys"
    echo_progress_done "SSH key added"
}

# ==============================================================================
# fail2ban Configuration
# ==============================================================================

configure_fail2ban() {
    local ssh_port="${1:-22}"

    echo_header "fail2ban Configuration"

    echo_progress_start "Installing fail2ban"
    apt-get update -qq
    apt-get install -y -qq fail2ban
    echo_progress_done "fail2ban installed"

    # Backup existing config
    backup_file "/etc/fail2ban/jail.local" "/opt/swizzin-extras/bootstrap-backups/fail2ban"

    echo_progress_start "Configuring fail2ban jails"

    cat > /etc/fail2ban/jail.local <<EOF
# Bootstrap fail2ban Configuration
# Generated: $(date)

[DEFAULT]
# Ban duration (1 hour)
bantime = 3600

# Time window for counting failures (10 minutes)
findtime = 600

# Max retries before ban
maxretry = 3

# Ignore local IPs
ignoreip = 127.0.0.1/8 ::1

# Action to take
banaction = iptables-multiport
banaction_allports = iptables-allports

# Email settings (disabled, using Pushover)
destemail = root@localhost
sendername = Fail2Ban
mta = sendmail
action = %(action_)s

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

[sshd-ddos]
enabled = true
port = ${ssh_port}
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 5
bantime = 86400
findtime = 600
EOF

    echo_progress_done "fail2ban jails configured"

    echo_progress_start "Starting fail2ban"
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo_progress_done "fail2ban started"

    echo_success "fail2ban configured for SSH on port $ssh_port"
}

# ==============================================================================
# UFW Firewall Configuration
# ==============================================================================

configure_ufw() {
    local ssh_port="${1:-22}"
    local -a extra_ports=("${@:2}")

    echo_header "UFW Firewall Configuration"

    echo_progress_start "Installing UFW"
    apt-get install -y -qq ufw
    echo_progress_done "UFW installed"

    # Backup existing rules
    if [[ -f /etc/ufw/user.rules ]]; then
        backup_file "/etc/ufw/user.rules" "/opt/swizzin-extras/bootstrap-backups/ufw"
    fi

    echo_progress_start "Configuring UFW rules"

    # Reset to defaults
    ufw --force reset >/dev/null 2>&1

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # SSH (always allowed)
    ufw allow "$ssh_port/tcp" comment 'SSH'

    # HTTP/HTTPS (always needed for web services)
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    # Extra ports if specified
    for port_spec in "${extra_ports[@]}"; do
        if [[ -n "$port_spec" ]]; then
            local port="${port_spec%%:*}"
            local comment="${port_spec#*:}"
            [[ "$comment" == "$port_spec" ]] && comment="Custom"
            ufw allow "$port/tcp" comment "$comment"
            echo_debug "Added UFW rule: $port/tcp ($comment)"
        fi
    done

    echo_progress_done "UFW rules configured"

    echo_progress_start "Enabling UFW"
    ufw --force enable
    echo_progress_done "UFW enabled"

    echo_success "UFW firewall configured"
    echo ""
    echo_info "Current UFW rules:"
    ufw status numbered
}

add_ufw_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local comment="${3:-Custom}"

    if validate_port_range "$port"; then
        ufw allow "${port}/${protocol}" comment "$comment"
        echo_info "Added UFW rule: ${port}/${protocol} ($comment)"
    else
        echo_error "Invalid port: $port"
        return 1
    fi
}

# ==============================================================================
# Unattended Upgrades Configuration
# ==============================================================================

configure_unattended_upgrades() {
    local reboot_time="${1:-04:00}"

    echo_header "Unattended Upgrades Configuration"

    echo_progress_start "Installing unattended-upgrades"
    apt-get install -y -qq unattended-upgrades apt-listchanges
    echo_progress_done "unattended-upgrades installed"

    # Backup existing config
    backup_file "/etc/apt/apt.conf.d/50unattended-upgrades" "/opt/swizzin-extras/bootstrap-backups/apt"

    echo_progress_start "Configuring automatic updates"

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Bootstrap Unattended-Upgrades Configuration
// Generated: $(date)

Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
    "\${distro_id}:\${distro_codename}-updates";
};

// Remove unused kernel packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatic reboot if required
Unattended-Upgrade::Automatic-Reboot "true";

// Reboot time
Unattended-Upgrade::Automatic-Reboot-Time "${reboot_time}";

// Reboot delay
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";

// Don't split upgrades
Unattended-Upgrade::MinimalSteps "false";

// Disable mail notifications (using Pushover instead)
Unattended-Upgrade::Mail "";
EOF

    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    echo_progress_done "Automatic updates configured"

    # Dry run to verify
    echo_progress_start "Verifying configuration"
    if unattended-upgrade --dry-run &>/dev/null; then
        echo_progress_done "Configuration verified"
    else
        echo_progress_fail "Configuration check failed"
        echo_warn "Unattended upgrades may not work correctly"
    fi

    echo_success "Unattended upgrades configured"
    echo_info "System will auto-reboot at $reboot_time if updates require it"
}

# ==============================================================================
# Run All Hardening
# ==============================================================================

run_hardening() {
    local ssh_port="${1:-22}"
    local ssh_key="${2:-}"
    local reboot_time="${3:-04:00}"

    configure_ssh "$ssh_port" "$ssh_key"

    echo ""
    echo_warn "Before continuing, verify SSH access in a new terminal:"
    echo_info "  ssh -p $ssh_port root@<server-ip>"
    echo ""

    if ! ask "Have you verified SSH access works?" N; then
        echo_error "Aborting. Please verify SSH access first."
        echo_info "To restore: bash $0 --restore-ssh"
        exit 1
    fi

    configure_fail2ban "$ssh_port"
    configure_ufw "$ssh_port"
    configure_unattended_upgrades "$reboot_time"

    echo ""
    echo_success "All hardening complete"
}
