#!/bin/bash
# validation.sh - OS checks, root check, network validation
# Part of swizzin-scripts bootstrap

# ==============================================================================
# Pre-flight Validation
# ==============================================================================

validate_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run as root"
        echo_info "Try: sudo bash $0"
        exit 1
    fi
    echo_debug "Root check passed"
}

validate_os() {
    local supported_distros=("ubuntu")
    local supported_versions=("22.04" "24.04")

    # Check if /etc/os-release exists
    if [[ ! -f /etc/os-release ]]; then
        echo_error "Cannot detect OS: /etc/os-release not found"
        exit 1
    fi

    # Source os-release
    # shellcheck source=/dev/null
    source /etc/os-release

    local distro_id="${ID,,}"  # lowercase
    local version_id="${VERSION_ID}"

    # Check distro
    local distro_ok=false
    for d in "${supported_distros[@]}"; do
        if [[ "$distro_id" == "$d" ]]; then
            distro_ok=true
            break
        fi
    done

    if [[ "$distro_ok" != "true" ]]; then
        echo_error "Unsupported distribution: $distro_id"
        echo_info "Supported: ${supported_distros[*]}"
        exit 1
    fi

    # Check version
    local version_ok=false
    for v in "${supported_versions[@]}"; do
        if [[ "$version_id" == "$v" ]]; then
            version_ok=true
            break
        fi
    done

    if [[ "$version_ok" != "true" ]]; then
        echo_error "Unsupported version: $version_id"
        echo_info "Supported versions: ${supported_versions[*]}"
        exit 1
    fi

    echo_success "OS validated: $PRETTY_NAME"

    # Export for later use
    export BOOTSTRAP_DISTRO="$distro_id"
    export BOOTSTRAP_VERSION="$version_id"
}

validate_architecture() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64|amd64)
            export BOOTSTRAP_ARCH="amd64"
            ;;
        aarch64|arm64)
            export BOOTSTRAP_ARCH="arm64"
            ;;
        *)
            echo_error "Unsupported architecture: $arch"
            echo_info "Supported: x86_64/amd64, aarch64/arm64"
            exit 1
            ;;
    esac

    echo_debug "Architecture: $BOOTSTRAP_ARCH"
}

validate_network() {
    echo_progress_start "Checking network connectivity"

    # Check DNS resolution
    if ! host -W 5 google.com &>/dev/null; then
        echo_progress_fail "DNS resolution failed"
        echo_error "Cannot resolve hostnames. Check your DNS configuration."
        exit 1
    fi

    # Check internet connectivity
    if ! curl -sf --max-time 10 https://swizzin.ltd &>/dev/null; then
        echo_progress_fail "Cannot reach swizzin.ltd"
        echo_error "Cannot reach Swizzin servers. Check your internet connection."
        exit 1
    fi

    # Check GitHub connectivity (needed for scripts)
    if ! curl -sf --max-time 10 https://api.github.com &>/dev/null; then
        echo_progress_fail "Cannot reach GitHub"
        echo_error "Cannot reach GitHub. Check your internet connection or firewall."
        exit 1
    fi

    echo_progress_done "Network connectivity verified"
}

validate_not_already_run() {
    local marker_file="/opt/swizzin-extras/bootstrap.done"

    if [[ -f "$marker_file" ]]; then
        echo_warn "Bootstrap has already been run on this server"
        echo_info "Marker file: $marker_file"

        if ask "Continue anyway? This may overwrite existing configuration" N; then
            echo_info "Continuing with bootstrap..."
            return 0
        else
            echo_info "Aborted. Remove $marker_file to force re-run."
            exit 0
        fi
    fi

    echo_debug "Fresh server - no previous bootstrap detected"
}

validate_disk_space() {
    local min_space_gb="${1:-10}"
    local target_dir="${2:-/}"

    local available_kb
    available_kb=$(df -k "$target_dir" | awk 'NR==2 {print $4}')
    local available_gb=$(( available_kb / 1024 / 1024 ))

    if (( available_gb < min_space_gb )); then
        echo_error "Insufficient disk space: ${available_gb}GB available, ${min_space_gb}GB required"
        exit 1
    fi

    echo_debug "Disk space check passed: ${available_gb}GB available"
}

validate_memory() {
    local min_memory_gb="${1:-4}"
    local warn_memory_gb="${2:-8}"

    local total_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_gb=$(( total_kb / 1024 / 1024 ))

    if (( total_gb < min_memory_gb )); then
        echo_error "Insufficient memory: ${total_gb}GB detected, ${min_memory_gb}GB minimum required"
        echo_info "For streaming/transcoding workloads, 8GB+ is recommended"
        if ! ask "Continue anyway? (Not recommended)" N; then
            exit 0
        fi
    elif (( total_gb < warn_memory_gb )); then
        echo_warn "Limited memory: ${total_gb}GB detected"
        echo_info "For optimal streaming/transcoding, 8GB+ RAM is recommended"
        echo_info "Concurrent transcoding may be limited with current memory"
    fi

    echo_debug "Memory check passed: ${total_gb}GB total"
    export BOOTSTRAP_MEMORY_GB="$total_gb"
}

validate_systemd() {
    if ! command_exists systemctl; then
        echo_error "systemd is required but not found"
        exit 1
    fi

    if ! systemctl is-system-running &>/dev/null; then
        local state
        state=$(systemctl is-system-running 2>/dev/null || echo "unknown")
        echo_warn "systemd state: $state"

        if [[ "$state" == "degraded" ]]; then
            echo_info "Some services may have failed. Continuing..."
        fi
    fi

    echo_debug "systemd check passed"
}

# ==============================================================================
# SSH Validation
# ==============================================================================

validate_ssh_key() {
    local key="$1"

    # Check if it's a file path
    if [[ -f "$key" ]]; then
        key=$(cat "$key")
    fi

    # Validate key format
    if [[ ! "$key" =~ ^ssh-(rsa|ed25519|ecdsa|dss)[[:space:]] ]]; then
        echo_error "Invalid SSH public key format"
        echo_info "Key should start with: ssh-rsa, ssh-ed25519, ssh-ecdsa, or ssh-dss"
        return 1
    fi

    # Basic structure check
    local parts
    IFS=' ' read -ra parts <<< "$key"
    if (( ${#parts[@]} < 2 )); then
        echo_error "Invalid SSH key structure"
        return 1
    fi

    echo_debug "SSH key validated"
    return 0
}

validate_ssh_connection() {
    local port="${1:-22}"

    # Check if we can still connect (important after port change!)
    echo_info "Testing SSH on port $port..."

    if ! nc -z 127.0.0.1 "$port" &>/dev/null; then
        echo_error "SSH is not listening on port $port"
        return 1
    fi

    return 0
}

# ==============================================================================
# Port Validation
# ==============================================================================

validate_port_available() {
    local port="$1"

    if ss -tuln | grep -q ":${port}[[:space:]]"; then
        return 1  # Port in use
    fi
    return 0  # Port available
}

validate_port_range() {
    local port="$1"
    local min="${2:-1}"
    local max="${3:-65535}"

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if (( port < min || port > max )); then
        return 1
    fi

    return 0
}

# ==============================================================================
# Domain Validation
# ==============================================================================

validate_domain() {
    local domain="$1"

    # Basic format check
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        echo_error "Invalid domain format: $domain"
        return 1
    fi

    # Check for spaces
    if [[ "$domain" =~ [[:space:]] ]]; then
        echo_error "Domain cannot contain spaces"
        return 1
    fi

    return 0
}

validate_domain_resolves() {
    local domain="$1"

    if ! host -W 5 "$domain" &>/dev/null; then
        echo_warn "Domain $domain does not resolve"
        echo_info "Make sure DNS is configured before requesting SSL certificates"
        return 1
    fi

    return 0
}

# ==============================================================================
# Run All Validations
# ==============================================================================

run_preflight_checks() {
    echo_header "Pre-flight Checks"

    validate_root
    validate_os
    validate_architecture
    validate_systemd
    validate_disk_space 10
    validate_memory 2
    validate_network
    validate_not_already_run

    echo ""
    echo_success "All pre-flight checks passed"
    echo ""
}
