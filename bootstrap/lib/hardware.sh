#!/bin/bash
# hardware.sh - GPU detection and hardware transcoding configuration
# Part of swizzin-scripts bootstrap

# ==============================================================================
# GPU Detection
# ==============================================================================

# Detect GPU type for hardware transcoding
# Returns: intel, nvidia, amd, or empty string if none detected
detect_gpu() {
    local gpu_type=""

    # Intel GPU (VAAPI/QuickSync)
    # Check for Intel integrated or discrete graphics
    if [[ -d /dev/dri ]]; then
        if lspci 2>/dev/null | grep -qi "vga.*intel\|display.*intel\|3d.*intel"; then
            gpu_type="intel"
        fi
    fi

    # NVIDIA GPU (NVENC)
    # Check for nvidia-smi or device files
    if [[ -z "$gpu_type" ]]; then
        if command -v nvidia-smi &>/dev/null; then
            gpu_type="nvidia"
        elif [[ -e /dev/nvidia0 ]]; then
            gpu_type="nvidia"
        elif lspci 2>/dev/null | grep -qi "vga.*nvidia\|3d.*nvidia"; then
            gpu_type="nvidia"
        fi
    fi

    # AMD GPU (VAAPI)
    if [[ -z "$gpu_type" ]]; then
        if [[ -d /dev/dri ]] && lspci 2>/dev/null | grep -qi "vga.*amd\|display.*amd\|vga.*radeon"; then
            gpu_type="amd"
        fi
    fi

    echo "$gpu_type"
}

# Get detailed GPU information
# Outputs GPU type, model, and device paths
get_gpu_info() {
    local gpu_type
    gpu_type=$(detect_gpu)

    if [[ -z "$gpu_type" ]]; then
        echo_info "No supported GPU detected for hardware transcoding"
        return 1
    fi

    echo_info "GPU Type: $gpu_type"

    case "$gpu_type" in
        intel)
            echo_info "GPU Model: $(lspci | grep -i 'vga\|display\|3d' | grep -i intel | head -1 | cut -d: -f3)"
            echo_info "Transcoding: VAAPI / Intel Quick Sync"
            if [[ -e /dev/dri/renderD128 ]]; then
                echo_info "Render device: /dev/dri/renderD128"
            fi
            ;;
        nvidia)
            if command -v nvidia-smi &>/dev/null; then
                echo_info "GPU Model: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
            else
                echo_info "GPU Model: $(lspci | grep -i 'vga\|3d' | grep -i nvidia | head -1 | cut -d: -f3)"
            fi
            echo_info "Transcoding: NVENC"
            ;;
        amd)
            echo_info "GPU Model: $(lspci | grep -i 'vga\|display' | grep -Ei 'amd|radeon' | head -1 | cut -d: -f3)"
            echo_info "Transcoding: VAAPI"
            if [[ -e /dev/dri/renderD128 ]]; then
                echo_info "Render device: /dev/dri/renderD128"
            fi
            ;;
    esac

    return 0
}

# ==============================================================================
# GPU Access Configuration
# ==============================================================================

# Configure GPU access for a user
# Arguments:
#   $1 - username to configure
# Returns: 0 on success, 1 if no GPU or user doesn't exist
configure_gpu_access() {
    local user="$1"
    local gpu_type
    gpu_type=$(detect_gpu)

    if [[ -z "$gpu_type" ]]; then
        echo_debug "No GPU detected, skipping GPU access configuration for $user"
        return 1
    fi

    if ! id "$user" &>/dev/null; then
        echo_debug "User $user does not exist, skipping GPU access configuration"
        return 1
    fi

    local groups_added=()

    case "$gpu_type" in
        intel|amd)
            # VAAPI requires render and video groups
            if getent group render &>/dev/null; then
                if ! groups "$user" | grep -qw render; then
                    usermod -aG render "$user" 2>/dev/null && groups_added+=("render")
                fi
            fi
            if getent group video &>/dev/null; then
                if ! groups "$user" | grep -qw video; then
                    usermod -aG video "$user" 2>/dev/null && groups_added+=("video")
                fi
            fi
            ;;
        nvidia)
            # NVENC requires video group
            if getent group video &>/dev/null; then
                if ! groups "$user" | grep -qw video; then
                    usermod -aG video "$user" 2>/dev/null && groups_added+=("video")
                fi
            fi
            ;;
    esac

    if [[ ${#groups_added[@]} -gt 0 ]]; then
        echo_info "Added $user to groups: ${groups_added[*]} (for $gpu_type hardware transcoding)"
        return 0
    else
        echo_debug "$user already has required group memberships for $gpu_type"
        return 0
    fi
}

# Check if user has GPU access
# Arguments:
#   $1 - username to check
# Returns: 0 if user has access, 1 otherwise
check_gpu_access() {
    local user="$1"
    local gpu_type
    gpu_type=$(detect_gpu)

    if [[ -z "$gpu_type" ]]; then
        return 1
    fi

    if ! id "$user" &>/dev/null; then
        return 1
    fi

    local user_groups
    user_groups=$(groups "$user" 2>/dev/null)

    case "$gpu_type" in
        intel|amd)
            if echo "$user_groups" | grep -qw render && echo "$user_groups" | grep -qw video; then
                return 0
            fi
            ;;
        nvidia)
            if echo "$user_groups" | grep -qw video; then
                return 0
            fi
            ;;
    esac

    return 1
}

# ==============================================================================
# GPU Device Access
# ==============================================================================

# Get GPU device paths for container mounting
# Returns device paths suitable for Docker volume mounts
get_gpu_devices() {
    local gpu_type
    gpu_type=$(detect_gpu)

    case "$gpu_type" in
        intel|amd)
            # Return DRI devices for VAAPI
            if [[ -d /dev/dri ]]; then
                echo "/dev/dri:/dev/dri"
            fi
            ;;
        nvidia)
            # Return NVIDIA devices
            local devices=""
            if [[ -e /dev/nvidia0 ]]; then
                devices="/dev/nvidia0:/dev/nvidia0"
            fi
            if [[ -e /dev/nvidiactl ]]; then
                [[ -n "$devices" ]] && devices="$devices,"
                devices="${devices}/dev/nvidiactl:/dev/nvidiactl"
            fi
            if [[ -e /dev/nvidia-uvm ]]; then
                [[ -n "$devices" ]] && devices="$devices,"
                devices="${devices}/dev/nvidia-uvm:/dev/nvidia-uvm"
            fi
            echo "$devices"
            ;;
    esac
}

# ==============================================================================
# Hardware Transcoding Hints
# ==============================================================================

# Print instructions for enabling hardware transcoding in media servers
print_transcoding_hints() {
    local gpu_type
    gpu_type=$(detect_gpu)

    if [[ -z "$gpu_type" ]]; then
        echo_info "No GPU detected for hardware transcoding"
        echo_info "Software transcoding will be used (CPU-intensive)"
        return
    fi

    echo_info "GPU detected: $gpu_type"
    echo ""

    case "$gpu_type" in
        intel)
            echo_info "To enable Intel Quick Sync transcoding:"
            echo_info "  Jellyfin: Dashboard > Playback > Transcoding"
            echo_info "    - Enable hardware acceleration: Intel Quick Sync (QSV)"
            echo_info "  Emby: Settings > Transcoding"
            echo_info "    - Enable hardware decoding/encoding"
            echo_info "  Plex: Settings > Transcoder"
            echo_info "    - Use hardware acceleration when available"
            ;;
        nvidia)
            echo_info "To enable NVENC transcoding:"
            echo_info "  Jellyfin: Dashboard > Playback > Transcoding"
            echo_info "    - Enable hardware acceleration: NVIDIA NVENC"
            echo_info "  Emby: Settings > Transcoding"
            echo_info "    - Enable NVIDIA hardware decoding/encoding"
            echo_info "  Plex: Settings > Transcoder"
            echo_info "    - Use hardware acceleration when available"
            echo_info ""
            echo_info "Note: Ensure NVIDIA drivers are installed"
            ;;
        amd)
            echo_info "To enable AMD VAAPI transcoding:"
            echo_info "  Jellyfin: Dashboard > Playback > Transcoding"
            echo_info "    - Enable hardware acceleration: Video Acceleration API (VAAPI)"
            echo_info "  Emby: Settings > Transcoding"
            echo_info "    - Enable hardware decoding"
            echo_info "  Plex: Settings > Transcoder"
            echo_info "    - Use hardware acceleration when available"
            ;;
    esac

    echo ""
    echo_info "After configuration, restart the media server service"
}
