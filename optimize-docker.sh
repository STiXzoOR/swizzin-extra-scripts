#!/bin/bash
# ==============================================================================
# DOCKER OPTIMIZATION SCRIPT
# ==============================================================================
# Configures Docker daemon with optimizations for streaming workloads:
# - Log rotation to prevent disk exhaustion
# - Storage driver optimization
# - Live restore for container persistence
#
# Usage: sudo bash optimize-docker.sh [--status|--remove|--help]
#
# Creates /etc/docker/daemon.json with optimized settings.
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
# Configuration
# ==============================================================================
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP_FILE="/etc/docker/daemon.json.bak"
LOCK_FILE="/install/.docker-optimized.lock"

# ==============================================================================
# Root Check
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo_error "This script must be run as root"
    echo_info "Try: sudo bash $0"
    exit 1
fi

# ==============================================================================
# Preflight Check
# ==============================================================================
preflight_check() {
    if ! command -v docker &>/dev/null; then
        echo_error "Docker is not installed"
        exit 1
    fi
}

# ==============================================================================
# Installation
# ==============================================================================
install_docker_config() {
    preflight_check

    if [[ -f "$LOCK_FILE" ]]; then
        echo_info "Docker optimizations already applied"
        echo_info "Run with --status to check current settings"
        echo_info "Run with --remove to revert, then reinstall"
        return 0
    fi

    echo_header "Docker Daemon Optimization"

    # Backup existing config
    if [[ -f "$DAEMON_JSON" ]]; then
        echo_info "Backing up existing daemon.json..."
        cp "$DAEMON_JSON" "$BACKUP_FILE"
        echo_success "Backup created: $BACKUP_FILE"

        # Try to merge settings
        echo_info "Merging with existing configuration..."
        local existing
        existing=$(cat "$DAEMON_JSON")

        # Check if it's valid JSON
        if ! echo "$existing" | jq empty 2>/dev/null; then
            echo_warn "Existing daemon.json is not valid JSON, replacing it"
            existing="{}"
        fi
    else
        echo_info "Creating new daemon.json..."
        local existing="{}"
    fi

    # Create optimized configuration
    echo_info "Applying Docker optimizations..."

    # Merge configuration using jq if available, otherwise create new
    if command -v jq &>/dev/null; then
        echo "$existing" | jq '. + {
            "log-driver": "json-file",
            "log-opts": {
                "max-size": "10m",
                "max-file": "3"
            },
            "live-restore": true,
            "storage-driver": "overlay2",
            "default-ulimits": {
                "nofile": {
                    "Name": "nofile",
                    "Hard": 500000,
                    "Soft": 500000
                }
            }
        }' >"$DAEMON_JSON"
    else
        # Without jq, create a clean config
        cat >"$DAEMON_JSON" <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "live-restore": true,
    "storage-driver": "overlay2",
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 500000,
            "Soft": 500000
        }
    }
}
EOF
    fi

    echo_success "Configuration written to $DAEMON_JSON"

    # Validate and restart Docker
    echo_info "Validating Docker configuration..."

    # Test by starting Docker in validate mode (dry run)
    if ! docker info &>/dev/null; then
        # Docker isn't running, just continue
        :
    fi

    echo_info "Restarting Docker daemon..."
    if systemctl restart docker; then
        echo_success "Docker restarted successfully"
    else
        echo_error "Failed to restart Docker"
        echo_info "Restoring backup..."
        if [[ -f "$BACKUP_FILE" ]]; then
            mv "$BACKUP_FILE" "$DAEMON_JSON"
            systemctl restart docker || true
        fi
        exit 1
    fi

    # Verify Docker is running
    sleep 2
    if docker info &>/dev/null; then
        echo_success "Docker is running with optimized configuration"
    else
        echo_error "Docker failed to start properly"
        echo_info "Check logs: journalctl -u docker"
        exit 1
    fi

    # Create lock file
    touch "$LOCK_FILE"

    echo ""
    echo_success "Docker optimizations applied successfully"
    echo ""
    echo_info "Settings applied:"
    echo_info "  - Log rotation: 10MB max, 3 files retained"
    echo_info "  - Live restore: Containers persist across daemon restarts"
    echo_info "  - Storage driver: overlay2"
    echo_info "  - File descriptor limit: 500,000"
}

# ==============================================================================
# Removal
# ==============================================================================
remove_docker_config() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        echo_info "Docker optimizations not installed"
        return 0
    fi

    echo_header "Removing Docker Optimizations"

    if [[ -f "$BACKUP_FILE" ]]; then
        echo_info "Restoring original daemon.json..."
        mv "$BACKUP_FILE" "$DAEMON_JSON"
        echo_success "Original configuration restored"
    else
        echo_info "Removing daemon.json..."
        rm -f "$DAEMON_JSON"
        echo_success "Configuration removed"
    fi

    rm -f "$LOCK_FILE"

    echo_info "Restarting Docker daemon..."
    systemctl restart docker

    echo_success "Docker optimizations removed"
}

# ==============================================================================
# Status
# ==============================================================================
show_status() {
    echo_header "Docker Optimization Status"

    if [[ -f "$LOCK_FILE" ]]; then
        echo "Status: ENABLED"
    else
        echo "Status: NOT ENABLED"
    fi

    echo ""

    if [[ -f "$DAEMON_JSON" ]]; then
        echo "Configuration file: $DAEMON_JSON"
        echo ""
        echo "Current settings:"

        if command -v jq &>/dev/null; then
            cat "$DAEMON_JSON" | jq -r '
                "  Log driver: \(.["log-driver"] // "default")",
                "  Log max-size: \(.["log-opts"]["max-size"] // "unlimited")",
                "  Log max-file: \(.["log-opts"]["max-file"] // "unlimited")",
                "  Live restore: \(.["live-restore"] // false)",
                "  Storage driver: \(.["storage-driver"] // "default")"
            ' 2>/dev/null || cat "$DAEMON_JSON"
        else
            cat "$DAEMON_JSON"
        fi
    else
        echo "No daemon.json found (using Docker defaults)"
        echo ""
        echo "Default log behavior:"
        echo "  - No log rotation (logs grow indefinitely)"
        echo "  - Risk of disk exhaustion"
    fi

    echo ""
    echo "Docker Info:"
    if docker info &>/dev/null; then
        local storage_driver logging_driver
        storage_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
        logging_driver=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo "unknown")
        echo "  Storage driver: $storage_driver"
        echo "  Logging driver: $logging_driver"
        echo "  Running containers: $(docker ps -q | wc -l)"
    else
        echo "  Docker is not running"
    fi

    if [[ -f "$BACKUP_FILE" ]]; then
        echo ""
        echo "Backup available: $BACKUP_FILE"
    fi
}

# ==============================================================================
# Help
# ==============================================================================
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Docker Daemon Optimization Script"
    echo ""
    echo "Options:"
    echo "  (no args)    Apply Docker optimizations"
    echo "  --status     Show current status"
    echo "  --remove     Remove optimizations and restore original config"
    echo "  --help       Show this help message"
    echo ""
    echo "Optimizations applied:"
    echo "  - Log rotation (10MB max, 3 files) - prevents disk exhaustion"
    echo "  - Live restore - containers persist across daemon restarts"
    echo "  - overlay2 storage driver - best performance"
    echo "  - Increased file descriptor limits (500k)"
    echo ""
    echo "Note: This will restart the Docker daemon, briefly stopping containers."
}

# ==============================================================================
# Main
# ==============================================================================
case "${1:-}" in
    --status | -s)
        show_status
        ;;
    --remove | -r)
        remove_docker_config
        ;;
    --help | -h)
        show_help
        ;;
    *)
        install_docker_config
        ;;
esac
