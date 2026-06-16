#!/bin/bash
# watchdog.sh - Generic service watchdog with health checks and notifications
# STiXzoOR 2026
# Usage: watchdog.sh /path/to/service.conf

set -euo pipefail

# ==============================================================================
# Constants
# ==============================================================================

GLOBAL_CONFIG="/opt/swizzin-extras/watchdog.conf"
LOG_DIR="/var/log/watchdog"
STATE_DIR="/var/lib/watchdog"

# Migrate state from old /var/run/watchdog (volatile) to /var/lib/watchdog (persistent)
if [[ -d "/var/run/watchdog" && ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR"
    chmod 750 "$STATE_DIR"
    cp /var/run/watchdog/*.state "$STATE_DIR/" 2>/dev/null || true
fi

# ==============================================================================
# Logging
# ==============================================================================

_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { _log "INFO" "$1"; }
log_warn() { _log "WARN" "$1"; }
log_error() { _log "ERROR" "$1"; }

# ==============================================================================
# Configuration Loading
# ==============================================================================

_load_global_config() {
    if [[ ! -f "$GLOBAL_CONFIG" ]]; then
        echo "ERROR: Global config not found: $GLOBAL_CONFIG"
        echo "Run the service-specific installer (e.g., emby-watchdog.sh --install) first."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$GLOBAL_CONFIG"

    # Set defaults
    DEFAULT_MAX_RESTARTS="${DEFAULT_MAX_RESTARTS:-3}"
    DEFAULT_COOLDOWN_WINDOW="${DEFAULT_COOLDOWN_WINDOW:-900}"
    DEFAULT_HEALTH_TIMEOUT="${DEFAULT_HEALTH_TIMEOUT:-10}"
}

_load_service_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Service config not found: $config_file"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$config_file"

    # Validate required fields
    if [[ -z "${SERVICE_NAME:-}" ]]; then
        echo "ERROR: SERVICE_NAME not set in $config_file"
        exit 1
    fi

    if [[ -z "${APP_NAME:-}" ]]; then
        APP_NAME="$SERVICE_NAME"
    fi

    if [[ -z "${HEALTH_URL:-}" ]]; then
        echo "ERROR: HEALTH_URL not set in $config_file"
        exit 1
    fi

    # Apply defaults
    MAX_RESTARTS="${MAX_RESTARTS:-$DEFAULT_MAX_RESTARTS}"
    COOLDOWN_WINDOW="${COOLDOWN_WINDOW:-$DEFAULT_COOLDOWN_WINDOW}"
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-$DEFAULT_HEALTH_TIMEOUT}"
    HEALTH_EXPECT="${HEALTH_EXPECT:-}"

    # Set file paths
    LOG_FILE="${LOG_FILE:-$LOG_DIR/${SERVICE_NAME}.log}"
    STATE_FILE="${STATE_FILE:-$STATE_DIR/${SERVICE_NAME}.state}"
    LOCK_FILE="${LOCK_FILE:-$STATE_DIR/${SERVICE_NAME}.lock}"
}

# ==============================================================================
# State Management
# ==============================================================================

_init_state() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat >"$STATE_FILE" <<EOF
RESTART_COUNT=0
RESTART_TIMESTAMPS=""
BACKOFF_UNTIL=""
EOF
    fi
}

_load_state() {
    # shellcheck source=/dev/null
    source "$STATE_FILE"

    RESTART_COUNT="${RESTART_COUNT:-0}"
    RESTART_TIMESTAMPS="${RESTART_TIMESTAMPS:-}"
    BACKOFF_UNTIL="${BACKOFF_UNTIL:-}"
}

_save_state() {
    cat >"$STATE_FILE" <<EOF
RESTART_COUNT=$RESTART_COUNT
RESTART_TIMESTAMPS="$RESTART_TIMESTAMPS"
BACKOFF_UNTIL="$BACKOFF_UNTIL"
EOF
}

_purge_old_timestamps() {
    local now
    now=$(date +%s)
    local cutoff=$((now - COOLDOWN_WINDOW))
    local new_timestamps=""
    local count=0

    IFS=',' read -ra timestamps <<<"$RESTART_TIMESTAMPS"
    for ts in "${timestamps[@]}"; do
        if [[ -n "$ts" && "$ts" -gt "$cutoff" ]]; then
            if [[ -n "$new_timestamps" ]]; then
                new_timestamps="${new_timestamps},${ts}"
            else
                new_timestamps="$ts"
            fi
            ((count++)) || true
        fi
    done

    RESTART_TIMESTAMPS="$new_timestamps"
    RESTART_COUNT="$count"
}

_add_restart_timestamp() {
    local now
    now=$(date +%s)

    if [[ -n "$RESTART_TIMESTAMPS" ]]; then
        RESTART_TIMESTAMPS="${RESTART_TIMESTAMPS},${now}"
    else
        RESTART_TIMESTAMPS="$now"
    fi

    ((RESTART_COUNT++)) || true
}

# ==============================================================================
# Notifications (shared library)
# ==============================================================================

# Override log warn before sourcing shared notifications
_notify_log_warn() { log_warn "$1"; }

# shellcheck source=../lib/notifications.sh
_notifications_lib="/opt/swizzin-extras/lib/notifications.sh"
[[ -f "$_notifications_lib" ]] || _notifications_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/notifications.sh"
if [[ ! -f "$_notifications_lib" ]]; then
    echo "ERROR: notifications.sh not found (tried /opt/swizzin-extras/lib/ and repo-relative path)" >&2
    echo "Re-run the watchdog installer to deploy the notifications library." >&2
    exit 1
fi
. "$_notifications_lib"
unset _notifications_lib
NOTIFY_RATE_DIR="$STATE_DIR"

# ==============================================================================
# Health Checks
# ==============================================================================

_check_process() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

_check_http() {
    local response http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" 2>/dev/null) || return 1

    # Validate HTTP response code (200-399 = success)
    if [[ "$http_code" -lt 200 || "$http_code" -ge 400 ]]; then
        log_warn "HTTP health check returned $http_code for $HEALTH_URL"
        return 1
    fi

    # If HEALTH_EXPECT is set, verify it exists in response body
    if [[ -n "$HEALTH_EXPECT" ]]; then
        response=$(curl -sf --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" 2>/dev/null) || return 1
        echo "$response" | grep -q "$HEALTH_EXPECT" || return 1
    fi

    return 0
}

_is_healthy() {
    if ! _check_process; then
        log_warn "Process check failed: $SERVICE_NAME is not running"
        return 1
    fi

    if ! _check_http; then
        log_warn "HTTP health check failed: $HEALTH_URL"
        return 1
    fi

    return 0
}

# ==============================================================================
# Restart Logic
# ==============================================================================

_get_service_uptime() {
    local active_enter
    active_enter=$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp --value 2>/dev/null)

    if [[ -z "$active_enter" || "$active_enter" == "n/a" ]]; then
        echo "0"
        return
    fi

    local active_epoch
    active_epoch=$(date -d "$active_enter" +%s 2>/dev/null) || echo "0"
    local now
    now=$(date +%s)

    echo $((now - active_epoch))
}

_detect_manual_restart() {
    local uptime
    uptime=$(_get_service_uptime)

    # If service was restarted recently (within cooldown window) and we're in backoff,
    # someone manually restarted it
    if [[ "$uptime" -lt "$COOLDOWN_WINDOW" && "$uptime" -gt 0 ]]; then
        return 0
    fi

    return 1
}

_restart_service() {
    log_info "Restarting $SERVICE_NAME..."

    if ! systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        log_error "Failed to restart $SERVICE_NAME"
        return 1
    fi

    log_info "Restart command issued, waiting 10 seconds for service to stabilize..."
    sleep 10

    # Verify health after restart
    if _is_healthy; then
        log_info "$SERVICE_NAME restarted successfully and is healthy"
        return 0
    else
        log_error "$SERVICE_NAME restarted but health check failed"
        return 1
    fi
}

# ==============================================================================
# Main Logic
# ==============================================================================

_run_watchdog() {
    local now
    now=$(date +%s)

    # Check if in backoff mode
    if [[ -n "$BACKOFF_UNTIL" && "$now" -lt "$BACKOFF_UNTIL" ]]; then
        # Check for manual restart
        if _check_process && _detect_manual_restart; then
            log_info "Manual restart detected, clearing backoff state"
            BACKOFF_UNTIL=""
            RESTART_COUNT=0
            RESTART_TIMESTAMPS=""
            _save_state
            _notify "$APP_NAME Watchdog" "Watchdog resumed after manual restart detected" "info"
        else
            log_info "In backoff mode until $(date -d "@$BACKOFF_UNTIL" '+%Y-%m-%d %H:%M:%S'), skipping"
            return 0
        fi
    fi

    # Run health checks
    if _is_healthy; then
        log_info "$APP_NAME is healthy"
        return 0
    fi

    # Service is unhealthy - purge old timestamps and check if we can restart
    _purge_old_timestamps

    local window_minutes=$((COOLDOWN_WINDOW / 60))

    if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
        # Max restarts reached - enter backoff
        log_error "Max restarts ($MAX_RESTARTS in ${window_minutes}min) reached, entering backoff"
        BACKOFF_UNTIL=$((now + COOLDOWN_WINDOW))
        _save_state
        if _should_notify "$SERVICE_NAME"; then
            _notify "$APP_NAME Watchdog" "Max restarts ($MAX_RESTARTS in ${window_minutes}min) reached. Giving up until manual intervention." "error"
        fi
        return 1
    fi

    # Attempt restart
    local attempt=$((RESTART_COUNT + 1))
    if _should_notify "$SERVICE_NAME"; then
        _notify "$APP_NAME Watchdog" "Service unhealthy, restarting (attempt $attempt/$MAX_RESTARTS)" "warning"
    fi

    if _restart_service; then
        _add_restart_timestamp
        _save_state
        _notify "$APP_NAME Watchdog" "Restarted successfully, health check passed" "info"
        return 0
    else
        _add_restart_timestamp
        _save_state
        _notify "$APP_NAME Watchdog" "Restart failed, service did not come up healthy" "error"
        return 1
    fi
}

# ==============================================================================
# Entry Point
# ==============================================================================

main() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 /path/to/service.conf"
        exit 1
    fi

    local service_config="$1"

    # Load configurations
    _load_global_config
    _load_service_config "$service_config"

    # Initialize state directory and files
    _init_state

    # Acquire lock
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "Another instance is already running for $SERVICE_NAME"
        exit 0
    fi

    # Load state
    _load_state

    # Run watchdog
    _run_watchdog
}

main "$@"
