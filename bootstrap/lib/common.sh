#!/bin/bash
# common.sh - Colors, logging, prompts, and utility functions
# Part of swizzin-scripts bootstrap

# ==============================================================================
# Colors and Formatting
# ==============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    BOLD=''
    NC=''
fi

# ==============================================================================
# Logging Functions
# ==============================================================================

_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO)    echo -e "${BLUE}[INFO]${NC} $message" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC} $message" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} $message" ;;
        DEBUG)   [[ "${DEBUG:-false}" == "true" ]] && echo -e "${MAGENTA}[DEBUG]${NC} $message" ;;
    esac

    # Also log to file if LOG_FILE is set
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

echo_info()    { _log INFO "$1"; }
echo_success() { _log SUCCESS "$1"; }
echo_warn()    { _log WARN "$1"; }
echo_error()   { _log ERROR "$1"; }
echo_debug()   { _log DEBUG "$1"; }

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
    echo -e "${BOLD}[${step}/${total}]${NC} $message"
}

# ==============================================================================
# Progress Indicators
# ==============================================================================

_spinner_pid=""

_start_spinner() {
    local message="$1"
    echo -ne "${BLUE}[...]${NC} $message "

    # Start background spinner
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

    # Clear line and print result
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
        echo "" >/dev/tty  # Ensure newline on terminal
        echo "${value:-$default}"
    else
        read -rp "$prompt: " value </dev/tty
        echo "" >/dev/tty  # Ensure newline on terminal
        echo "$value"
    fi
}

prompt_secret() {
    local prompt="$1"
    local value

    # Using visible input - secrets are entered during interactive setup anyway
    read -rp "$prompt: " value </dev/tty
    echo "" >/dev/tty  # Ensure newline on terminal
    echo "$value"
}

prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice

    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done

    while true; do
        read -rp "Choice [1-${#options[@]}]: " choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        echo_warn "Invalid choice. Please enter a number between 1 and ${#options[@]}"
    done
}

prompt_multiselect() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=()

    echo "$prompt (space to toggle, enter to confirm)"

    local states=()
    for _ in "${options[@]}"; do
        states+=(false)
    done

    local current=0
    while true; do
        # Display options
        for i in "${!options[@]}"; do
            local marker="[ ]"
            [[ "${states[$i]}" == "true" ]] && marker="[x]"
            if (( i == current )); then
                echo -e "  ${BOLD}> $marker ${options[$i]}${NC}"
            else
                echo "    $marker ${options[$i]}"
            fi
        done

        # Read single key
        read -rsn1 key </dev/tty

        # Clear displayed options
        for _ in "${options[@]}"; do
            echo -ne "\033[1A\033[K"
        done

        case "$key" in
            A) (( current > 0 )) && (( current-- )) ;;  # Up arrow
            B) (( current < ${#options[@]} - 1 )) && (( current++ )) ;;  # Down arrow
            " ") [[ "${states[$current]}" == "true" ]] && states[$current]=false || states[$current]=true ;;
            "") break ;;  # Enter
        esac
    done

    # Return selected items
    for i in "${!options[@]}"; do
        [[ "${states[$i]}" == "true" ]] && selected+=("${options[$i]}")
    done

    printf '%s\n' "${selected[@]}"
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

backup_file() {
    local file="$1"
    local backup_dir="${2:-/opt/swizzin-extras/bootstrap-backups}"

    if [[ -f "$file" ]]; then
        mkdir -p "$backup_dir"
        local filename
        filename=$(basename "$file")
        local backup_path="$backup_dir/${filename}.$(date +%Y%m%d%H%M%S).bak"
        cp "$file" "$backup_path"
        echo_debug "Backed up $file to $backup_path"
        echo "$backup_path"
    fi
}

# Generate random string
random_string() {
    local length="${1:-32}"
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
}

# Generate random port in range
random_port() {
    local min="${1:-10000}"
    local max="${2:-65000}"
    shuf -i "$min-$max" -n 1
}

# Wait for service to be ready
wait_for_service() {
    local service="$1"
    local timeout="${2:-30}"
    local count=0

    while ! systemctl is-active --quiet "$service"; do
        sleep 1
        (( count++ ))
        if (( count >= timeout )); then
            return 1
        fi
    done
    return 0
}

# Wait for port to be listening
wait_for_port() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    local timeout="${3:-30}"
    local count=0

    while ! nc -z "$host" "$port" 2>/dev/null; do
        sleep 1
        (( count++ ))
        if (( count >= timeout )); then
            return 1
        fi
    done
    return 0
}
