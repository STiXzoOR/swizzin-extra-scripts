#!/bin/bash
# ==============================================================================
# STREAMING PERFORMANCE OPTIMIZATION SCRIPT
# ==============================================================================
# Applies system-level optimizations for streaming workloads:
# - CPU governor: performance mode
# - NVMe I/O scheduler: none (direct access)
# - Network: expanded port range, RPS enabled
# - GPU: adds media server users to render/video groups
# - Sysctl: reloads streaming-optimized settings
#
# Usage: sudo bash optimize-streaming.sh [--status|--help]
#
# This script makes immediate changes and creates persistent configurations.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Signal Traps
# ==============================================================================
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Source Bootstrap Library (if available)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/bootstrap/lib/common.sh" ]]; then
    # shellcheck source=bootstrap/lib/common.sh
    . "${SCRIPT_DIR}/bootstrap/lib/common.sh"
else
    # Fallback logging functions
    echo_info() { echo "[INFO] $1"; }
    echo_success() { echo "[OK] $1"; }
    echo_warn() { echo "[WARN] $1"; }
    echo_error() { echo "[ERROR] $1"; }
    echo_header() {
        echo ""
        echo "=== $1 ==="
        echo ""
    }
fi

# ==============================================================================
# Root Check
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo_error "This script must be run as root"
    echo_info "Try: sudo bash $0"
    exit 1
fi

# ==============================================================================
# CPU Governor Configuration
# ==============================================================================
configure_cpu_governor() {
    echo_header "CPU Governor Configuration"

    local current_governor
    current_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")

    echo_info "Current CPU governor: $current_governor"

    if [[ "$current_governor" == "performance" ]]; then
        echo_success "CPU governor already set to performance"
        return 0
    fi

    # Apply immediately
    echo_info "Setting CPU governor to performance..."
    if echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1; then
        echo_success "CPU governor set to performance"
    else
        echo_warn "Could not set CPU governor (may not be supported)"
        return 0
    fi

    # Create systemd service for persistence
    if [[ ! -f /etc/systemd/system/cpu-performance.service ]]; then
        echo_info "Creating persistent CPU governor service..."
        cat >/etc/systemd/system/cpu-performance.service <<'EOF'
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable cpu-performance.service >/dev/null 2>&1
        echo_success "CPU governor persistence configured"
    fi
}

# ==============================================================================
# NVMe I/O Scheduler Configuration
# ==============================================================================
configure_nvme_scheduler() {
    echo_header "NVMe I/O Scheduler Configuration"

    local nvme_found=false

    for scheduler in /sys/block/nvme*/queue/scheduler; do
        if [[ -f "$scheduler" ]]; then
            nvme_found=true
            local device
            device=$(echo "$scheduler" | grep -oP 'nvme\d+n\d+')
            local current
            current=$(cat "$scheduler" | grep -oP '\[\K[^\]]+' || cat "$scheduler")

            echo_info "Device: $device, Current scheduler: $current"

            if [[ "$current" == "none" ]]; then
                echo_success "$device already using 'none' scheduler"
            else
                echo "none" >"$scheduler" 2>/dev/null \
                    && echo_success "$device scheduler set to 'none'" \
                    || echo_warn "Could not set scheduler for $device"
            fi
        fi
    done

    if [[ "$nvme_found" == "false" ]]; then
        echo_info "No NVMe devices found, skipping scheduler configuration"
        return 0
    fi

    # Create udev rule for persistence
    if [[ ! -f /etc/udev/rules.d/60-nvme-scheduler.rules ]]; then
        echo_info "Creating persistent NVMe scheduler rule..."
        cat >/etc/udev/rules.d/60-nvme-scheduler.rules <<'EOF'
# Set NVMe I/O scheduler to none for direct access
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
        echo_success "NVMe scheduler persistence configured"
    fi
}

# ==============================================================================
# Network Tuning
# ==============================================================================
configure_network() {
    echo_header "Network Tuning"

    # Write comprehensive streaming sysctl config
    # Uses separate file from bootstrap/lib/tuning.sh (99-streaming.conf).
    # Name sorts AFTER 99-streaming.conf (`-` < `.` in ASCII would load us
    # first and let bootstrap overwrite), so we use 99-zz- prefix to win.
    local sysctl_file="/etc/sysctl.d/99-zz-streaming-optimizer.conf"
    # Remove legacy name if present from older installs.
    rm -f /etc/sysctl.d/99-streaming-optimizer.conf

    echo_info "Writing streaming sysctl configuration..."
    cat >"$sysctl_file" <<'SYSCTL'
# Streaming-optimized sysctl parameters
# Generated by swizzin-scripts optimize-streaming.sh
# Complements bootstrap/lib/tuning.sh (99-streaming.conf)

# Ephemeral port range (maximize outbound connections)
net.ipv4.ip_local_port_range = 1024 65535

# TCP connection reuse and timeouts
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Connection tracking (override bootstrap's 86400s timeout)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120

# UDP buffer tuning for streaming
net.ipv4.udp_mem = 94500000 915000000 927000000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Receive Packet Steering
net.core.rps_sock_flow_entries = 512000
net.core.optmem_max = 67108864
SYSCTL
    echo_success "Sysctl config written to $sysctl_file"
}

# ==============================================================================
# Sysctl Reload
# ==============================================================================
reload_sysctl() {
    echo_header "Sysctl Configuration"

    echo_info "Reloading sysctl configuration..."
    if sysctl --system >/dev/null 2>&1; then
        echo_success "Sysctl settings reloaded"
    else
        echo_warn "Some sysctl settings may have failed to load"
    fi

    # Verify conntrack timeout
    local conntrack_timeout
    conntrack_timeout=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo "unknown")
    echo_info "Conntrack timeout: ${conntrack_timeout}s"
}

# ==============================================================================
# Filesystem Optimization Check
# ==============================================================================
check_filesystem() {
    echo_header "Filesystem Configuration"

    if grep -q "noatime" /etc/fstab; then
        echo_success "noatime already configured in fstab"
    else
        echo_warn "Consider adding 'noatime' to root mount in /etc/fstab"
        echo_info "This reduces unnecessary metadata writes during file reads"
    fi
}

# ==============================================================================
# GPU Access for Media Servers
# ==============================================================================
configure_gpu_access() {
    echo_header "GPU Access Configuration"

    # Detect GPU type
    local gpu_type=""
    if [[ -d /dev/dri ]] && lspci 2>/dev/null | grep -qi "vga.*intel\|display.*intel"; then
        gpu_type="intel"
        echo_info "Detected: Intel GPU (VAAPI/QuickSync)"
    elif command -v nvidia-smi &>/dev/null || [[ -e /dev/nvidia0 ]]; then
        gpu_type="nvidia"
        echo_info "Detected: NVIDIA GPU"
    elif [[ -d /dev/dri ]] && lspci 2>/dev/null | grep -qi "vga.*amd\|display.*amd"; then
        gpu_type="amd"
        echo_info "Detected: AMD GPU (VAAPI)"
    else
        echo_info "No supported GPU detected for hardware transcoding"
        return 0
    fi

    # Configure access for media server users
    local media_users=("jellyfin" "emby" "plex")
    local groups_to_add=()

    case "$gpu_type" in
        intel | amd)
            groups_to_add=("render" "video")
            ;;
        nvidia)
            groups_to_add=("video")
            ;;
    esac

    for user in "${media_users[@]}"; do
        if id "$user" &>/dev/null; then
            local user_groups
            user_groups=$(groups "$user" 2>/dev/null)

            for group in "${groups_to_add[@]}"; do
                if echo "$user_groups" | grep -qw "$group"; then
                    echo_info "$user already in $group group"
                else
                    if usermod -aG "$group" "$user" 2>/dev/null; then
                        echo_success "Added $user to $group group"
                    else
                        echo_warn "Could not add $user to $group group"
                    fi
                fi
            done
        fi
    done

    # Verify GPU device permissions
    if [[ -d /dev/dri ]]; then
        echo_info "GPU devices:"
        for dev in /dev/dri/card* /dev/dri/render*; do
            [[ -e "$dev" ]] || continue
            local line
            line=$(ls -la "$dev" 2>/dev/null) || continue
            echo_info "  $line"
        done
    fi

    echo ""
    echo_info "To enable hardware transcoding:"
    echo_info "  Jellyfin: Dashboard > Playback > Enable Intel Quick Sync"
    echo_info "  Emby: Settings > Transcoding > Enable hardware acceleration"
    echo_info "  Plex: Settings > Transcoder > Use hardware acceleration"
}

# ==============================================================================
# Status Report
# ==============================================================================
show_status() {
    echo_header "Streaming Optimization Status"

    echo "CPU Governor:"
    local governor
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    if [[ "$governor" == "performance" ]]; then
        echo "  Status: OPTIMIZED ($governor)"
    else
        echo "  Status: NOT OPTIMIZED ($governor)"
    fi

    echo ""
    echo "NVMe Scheduler:"
    local nvme_status="N/A"
    for scheduler in /sys/block/nvme*/queue/scheduler; do
        if [[ -f "$scheduler" ]]; then
            local device
            device=$(echo "$scheduler" | grep -oP 'nvme\d+n\d+')
            local current
            current=$(cat "$scheduler" | grep -oP '\[\K[^\]]+' || cat "$scheduler")
            if [[ "$current" == "none" ]]; then
                echo "  $device: OPTIMIZED (none)"
            else
                echo "  $device: NOT OPTIMIZED ($current)"
            fi
        fi
    done

    echo ""
    echo "Port Range:"
    local ports
    ports=$(cat /proc/sys/net/ipv4/ip_local_port_range | tr '\t' '-')
    echo "  Current: $ports"

    echo ""
    echo "RPS:"
    local rps
    rps=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo "0")
    if [[ "$rps" != "0" ]]; then
        echo "  Status: ENABLED ($rps entries)"
    else
        echo "  Status: DISABLED"
    fi

    echo ""
    echo "GPU Access:"
    if [[ -d /dev/dri ]]; then
        for user in jellyfin emby plex; do
            if id "$user" &>/dev/null; then
                local has_render has_video
                has_render=$(groups "$user" 2>/dev/null | grep -wq render && echo "yes" || echo "no")
                has_video=$(groups "$user" 2>/dev/null | grep -wq video && echo "yes" || echo "no")
                echo "  $user: render=$has_render, video=$has_video"
            fi
        done
    else
        echo "  No GPU devices found"
    fi

    echo ""
    echo "Sysctl Streaming Config:"
    if [[ -f /etc/sysctl.d/99-streaming.conf ]]; then
        echo "  Bootstrap tuning (99-streaming.conf): PRESENT"
    else
        echo "  Bootstrap tuning (99-streaming.conf): NOT FOUND"
    fi
    if [[ -f /etc/sysctl.d/99-zz-streaming-optimizer.conf ]]; then
        echo "  Optimizer tuning (99-zz-streaming-optimizer.conf): PRESENT"
    elif [[ -f /etc/sysctl.d/99-streaming-optimizer.conf ]]; then
        echo "  Optimizer tuning (legacy 99-streaming-optimizer.conf): PRESENT (will be renamed on next run)"
    else
        echo "  Optimizer tuning: NOT FOUND"
    fi

    echo ""
    echo "Persistence:"
    echo "  CPU governor service: $(systemctl is-enabled cpu-performance.service 2>/dev/null || echo "not installed")"
    echo "  NVMe udev rule: $([ -f /etc/udev/rules.d/60-nvme-scheduler.rules ] && echo "present" || echo "not installed")"
}

# ==============================================================================
# Help
# ==============================================================================
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Streaming Performance Optimization Script"
    echo ""
    echo "Options:"
    echo "  (no args)    Apply all optimizations"
    echo "  --status     Show current optimization status"
    echo "  --help       Show this help message"
    echo ""
    echo "Optimizations applied:"
    echo "  - CPU governor set to 'performance'"
    echo "  - NVMe I/O scheduler set to 'none'"
    echo "  - Ephemeral port range expanded to 1024-65535"
    echo "  - Receive Packet Steering (RPS) enabled"
    echo "  - Sysctl streaming settings reloaded"
    echo "  - Media server users added to GPU groups"
    echo ""
    echo "After running, restart media servers to apply GPU changes:"
    echo "  systemctl restart jellyfin emby-server plexmediaserver"
}

# ==============================================================================
# Main
# ==============================================================================
case "${1:-}" in
    --status | -s)
        show_status
        ;;
    --help | -h)
        show_help
        ;;
    *)
        echo_header "Streaming Performance Optimizer"
        echo_info "Applying system optimizations for streaming workloads..."
        echo ""

        configure_cpu_governor
        configure_nvme_scheduler
        configure_network
        reload_sysctl
        check_filesystem
        configure_gpu_access

        echo ""
        echo_header "Optimization Complete"
        echo_success "All optimizations applied"
        echo ""
        echo_info "To verify: bash $0 --status"
        echo_info "Restart media servers to apply GPU changes:"
        echo_info "  systemctl restart jellyfin emby-server plexmediaserver"
        ;;
esac
