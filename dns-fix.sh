#!/bin/bash
set -euo pipefail
# dns-fix.sh - DNS and IPv6 configuration helper
# STiXzoOR 2025
# Usage: bash dns-fix.sh [--revert|--status]
#
# Fixes DNS resolution issues that can affect FlareSolverr/Byparr cookie validation.
# Configures system to use reliable public DNS (8.8.8.8, 1.1.1.1) and optionally disables IPv6.

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Signal Traps
# ==============================================================================
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

backup_dir="/opt/swizzin-extras/dns-backups"
sysctl_conf="/etc/sysctl.d/99-disable-ipv6.conf"

# Detect DNS configuration method
_detect_dns_method() {
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "systemd-resolved"
    elif [[ -L /etc/resolv.conf ]]; then
        # Check if it's a symlink to systemd-resolved
        local target
        target=$(readlink -f /etc/resolv.conf 2>/dev/null)
        if [[ "$target" == *"systemd"* ]]; then
            echo "systemd-resolved"
        else
            echo "resolv.conf"
        fi
    else
        echo "resolv.conf"
    fi
}

# Show current DNS status
_show_status() {
    local method
    method=$(_detect_dns_method)

    local ipv6_disabled
    ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")

    local ipv6_status
    if [[ "$ipv6_disabled" == "1" ]]; then
        ipv6_status="DISABLED"
    else
        ipv6_status="ENABLED"
    fi

    echo ""
    echo "Current Configuration"
    echo "─────────────────────────────"
    printf "  %-14s %s\n" "DNS Method:" "${method}"

    # Get DNS servers
    local dns_servers=""
    if [[ "$method" == "systemd-resolved" ]]; then
        dns_servers=$(resolvectl status 2>/dev/null | grep -E "DNS Servers:" | head -1 | sed 's/.*DNS Servers: //' | tr -s ' ' ', ')
        if [[ -z "$dns_servers" ]]; then
            dns_servers=$(resolvectl status 2>/dev/null | grep -E "Current DNS Server:" | head -1 | sed 's/.*Current DNS Server: //')
        fi
    else
        dns_servers=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
    fi
    printf "  %-14s %s\n" "DNS Servers:" "${dns_servers:-unknown}"
    printf "  %-14s %s\n" "IPv6:" "${ipv6_status}"

    # Show backups if they exist
    if [[ -d "$backup_dir" ]] && [[ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
        printf "  %-14s %s\n" "Backups:" "${backup_dir}"
    fi
    echo ""
}

# Backup current configuration
_backup_config() {
    mkdir -p "$backup_dir"

    local method
    method=$(_detect_dns_method)

    if [[ "$method" == "systemd-resolved" ]]; then
        if [[ -f /etc/systemd/resolved.conf ]]; then
            cp /etc/systemd/resolved.conf "${backup_dir}/resolved.conf.bak"
        fi
    else
        if [[ -f /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
            cp /etc/resolv.conf "${backup_dir}/resolv.conf.bak"
        fi
    fi

    # Backup sysctl ipv6 settings
    sysctl -a 2>/dev/null | grep -E "^net.ipv6.conf.(all|default).disable_ipv6" >"${backup_dir}/ipv6-sysctl.bak"
}

# Configure DNS servers
_configure_dns() {
    local method
    method=$(_detect_dns_method)

    echo_progress_start "Configuring DNS servers (8.8.8.8, 1.1.1.1)"

    if [[ "$method" == "systemd-resolved" ]]; then
        # Configure systemd-resolved
        cat >/etc/systemd/resolved.conf <<-EOF
			[Resolve]
			DNS=8.8.8.8 1.1.1.1
			FallbackDNS=8.8.4.4 1.0.0.1
			DNSOverTLS=opportunistic
		EOF
        systemctl restart systemd-resolved >>"$log" 2>&1
    else
        # Direct resolv.conf modification
        # First, check if it's managed by resolvconf or similar
        if [[ -f /etc/resolvconf/resolv.conf.d/head ]]; then
            cat >/etc/resolvconf/resolv.conf.d/head <<-EOF
				nameserver 8.8.8.8
				nameserver 1.1.1.1
			EOF
            resolvconf -u >>"$log" 2>&1 || true
        else
            # Direct modification (may be overwritten by DHCP)
            cat >/etc/resolv.conf <<-EOF
				nameserver 8.8.8.8
				nameserver 1.1.1.1
				nameserver 8.8.4.4
			EOF
            # Try to make it immutable to prevent DHCP overwriting
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi
    fi

    echo_progress_done "DNS configured"
}

# Check if server has IPv4 connectivity
_has_ipv4() {
    # Check if any interface has a non-loopback IPv4 address
    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && return 0
    return 1
}

# Disable IPv6
_disable_ipv6() {
    # Safety check: ensure we have IPv4 before disabling IPv6
    if ! _has_ipv4; then
        echo_error "No IPv4 connectivity detected - disabling IPv6 could lock you out!"
        echo_error "Skipping IPv6 disable for safety"
        return 1
    fi

    echo_progress_start "Disabling IPv6"

    # Apply immediately
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >>"$log" 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >>"$log" 2>&1

    # Persist across reboots
    cat >"$sysctl_conf" <<-EOF
		# Disable IPv6 - applied by dns-fix.sh
		net.ipv6.conf.all.disable_ipv6 = 1
		net.ipv6.conf.default.disable_ipv6 = 1
	EOF

    echo_progress_done "IPv6 disabled"
}

# Restart affected services
_restart_affected_services() {
    local master_user
    master_user=$(_get_master_username)

    # Simple services
    for svc in byparr flaresolverr; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo_progress_start "Restarting ${svc}"
            systemctl restart "$svc" >>"$log" 2>&1
            echo_progress_done "${svc} restarted"
        fi
    done

    # Jackett uses templated service jackett@user
    if systemctl is-active --quiet "jackett@${master_user}" 2>/dev/null; then
        echo_progress_start "Restarting jackett@${master_user}"
        systemctl restart "jackett@${master_user}" >>"$log" 2>&1
        echo_progress_done "jackett restarted"
    fi
}

# Enable IPv6
_enable_ipv6() {
    echo_progress_start "Enabling IPv6"

    # Apply immediately
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >>"$log" 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >>"$log" 2>&1

    # Remove persistent config
    rm -f "$sysctl_conf"

    echo_progress_done "IPv6 enabled"
}

# Revert to original configuration
_revert() {
    echo_info "Reverting DNS configuration..."

    local method
    method=$(_detect_dns_method)

    if [[ "$method" == "systemd-resolved" ]]; then
        if [[ -f "${backup_dir}/resolved.conf.bak" ]]; then
            echo_progress_start "Restoring systemd-resolved config"
            cp "${backup_dir}/resolved.conf.bak" /etc/systemd/resolved.conf
            systemctl restart systemd-resolved >>"$log" 2>&1
            echo_progress_done "Config restored"
        else
            echo_info "No backup found, resetting to defaults"
            rm -f /etc/systemd/resolved.conf
            systemctl restart systemd-resolved >>"$log" 2>&1
        fi
    else
        if [[ -f "${backup_dir}/resolv.conf.bak" ]]; then
            echo_progress_start "Restoring resolv.conf"
            # Remove immutable flag if set
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cp "${backup_dir}/resolv.conf.bak" /etc/resolv.conf
            echo_progress_done "Config restored"
        else
            echo_info "No resolv.conf backup found"
        fi
    fi

    # Re-enable IPv6
    _enable_ipv6

    echo_success "DNS configuration reverted"
    echo_info "You may need to restart affected services (byparr, jackett, etc.)"
}

# Main install flow
_install() {
    echo_info "DNS Fix for FlareSolverr/Byparr"
    echo_info "This will configure public DNS and optionally disable IPv6"
    echo ""
    echo_warn "SAFETY NOTE: This script modifies system DNS settings."
    echo_warn "SSH access should remain unaffected (SSH uses IP, not DNS)."
    echo_warn "Backups are created automatically. Use --revert to undo."
    echo ""

    _show_status

    if ! ask "Would you like to apply the DNS fix?" Y; then
        echo_info "Cancelled"
        exit 0
    fi

    # Backup current config
    echo_progress_start "Backing up current configuration"
    _backup_config
    echo_progress_done "Backup saved to ${backup_dir}"

    # Configure DNS
    _configure_dns

    # Ask about IPv6
    echo ""
    echo_info "Disabling IPv6 can help if DNS resolution differs between IPv4/IPv6"
    if ask "Would you like to disable IPv6?" Y; then
        _disable_ipv6
    fi

    echo ""
    echo_success "DNS fix applied"
    echo_info "Restarting affected services..."
    _restart_affected_services

    echo ""
    echo_info "Test your indexers in Jackett now"
    echo_info "To revert: bash dns-fix.sh --revert"
}

# Main
case "${1:-}" in
    "--revert")
        _revert
        ;;
    "--status")
        _show_status
        ;;
    "--disable-ipv6")
        _show_status
        if ! ask "Disable IPv6?" Y; then
            echo_info "Cancelled"
            exit 0
        fi
        _disable_ipv6
        _restart_affected_services
        echo_success "IPv6 disabled"
        echo_info "To re-enable: bash dns-fix.sh --enable-ipv6"
        ;;
    "--enable-ipv6")
        _enable_ipv6
        echo_success "IPv6 enabled"
        ;;
    "")
        _install
        ;;
    *)
        echo "Usage: $0 [--revert|--status|--disable-ipv6|--enable-ipv6]"
        echo ""
        echo "  (no args)       Apply DNS fix (configure public DNS, optionally disable IPv6)"
        echo "  --status        Show current DNS configuration"
        echo "  --revert        Revert to original configuration"
        echo "  --disable-ipv6  Only disable IPv6 (no DNS changes)"
        echo "  --enable-ipv6   Re-enable IPv6"
        exit 1
        ;;
esac
