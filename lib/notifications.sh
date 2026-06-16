#!/bin/bash
# ==============================================================================
# Shared Notification Library
# ==============================================================================
# Source this file from scripts that need notification support:
#   . "${SCRIPT_DIR}/lib/notifications.sh" 2>/dev/null || true
#
# Required variables (set before calling _notify):
#   DISCORD_WEBHOOK, PUSHOVER_USER, PUSHOVER_TOKEN,
#   NOTIFIARR_API_KEY, EMAIL_TO  (all optional, empty = skip)
#
# Provides:
#   _notify             - Send notification to all configured channels
#   _notify_discord     - Send Discord webhook
#   _notify_pushover    - Send Pushover notification
#   _notify_notifiarr   - Send Notifiarr passthrough
#   _notify_email       - Send email via sendmail/mail
#   _should_notify      - Rate limiting check
# ==============================================================================

# Internal warning logger - override _notify_log_warn before sourcing to customize
if ! declare -f _notify_log_warn &>/dev/null; then
    _notify_log_warn() {
        echo "[WARN] $1" >&2
    }
fi

# Escape a string for safe embedding in a JSON value.
# Handles: backslash, double-quote, newline, carriage return, tab.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

_notify_discord() {
    local title="$1"
    local message="$2"
    local level="$3"

    local color
    case "$level" in
        info) color=3066993 ;;     # green
        warning) color=16776960 ;; # yellow
        error) color=15158332 ;;   # red
        *) color=3447003 ;;        # blue
    esac

    local safe_title safe_message
    safe_title=$(_json_escape "$title")
    safe_message=$(_json_escape "$message")

    local payload
    payload="{\"embeds\":[{\"title\":\"${safe_title}\",\"description\":\"${safe_message}\",\"color\":${color},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}"

    curl -sf -H "Content-Type: application/json" \
        -d "$payload" \
        "$DISCORD_WEBHOOK" >/dev/null 2>&1 || _notify_log_warn "Discord notification failed"
}

_notify_pushover() {
    local title="$1"
    local message="$2"
    local level="$3"

    local priority=0
    case "$level" in
        error) priority=1 ;;
        warning) priority=0 ;;
        *) priority=-1 ;;
    esac

    curl -sf \
        --config <(printf 'form = "token=%s"\nform = "user=%s"' "$PUSHOVER_TOKEN" "$PUSHOVER_USER") \
        --form-string "title=$title" \
        --form-string "message=$message" \
        --form-string "priority=$priority" \
        "https://api.pushover.net/1/messages.json" >/dev/null 2>&1 || _notify_log_warn "Pushover notification failed"
}

_notify_notifiarr() {
    local title="$1"
    local message="$2"
    local level="$3"

    local event
    case "$level" in
        error) event="error" ;;
        warning) event="warning" ;;
        *) event="info" ;;
    esac

    local safe_title safe_message
    safe_title=$(_json_escape "$title")
    safe_message=$(_json_escape "$message")

    curl -sf --config <(printf 'header = "x-api-key: %s"' "$NOTIFIARR_API_KEY") \
        -H "Content-Type: application/json" \
        -d "{\"event\":\"${event}\",\"title\":\"${safe_title}\",\"message\":\"${safe_message}\"}" \
        "https://notifiarr.com/api/v1/notification/passthrough" >/dev/null 2>&1 || _notify_log_warn "Notifiarr notification failed"
}

_notify_email() {
    local title="$1"
    local message="$2"
    local level="$3"

    if command -v sendmail &>/dev/null; then
        echo -e "Subject: [$level] $title\n\n$message" | sendmail "$EMAIL_TO" 2>/dev/null || _notify_log_warn "Email notification failed"
    elif command -v mail &>/dev/null; then
        echo "$message" | mail -s "[$level] $title" "$EMAIL_TO" 2>/dev/null || _notify_log_warn "Email notification failed"
    else
        _notify_log_warn "No mail command available for email notification"
    fi
}

_notify() {
    local title="$1"
    local message="$2"
    local level="${3:-info}"

    [[ -n "${DISCORD_WEBHOOK:-}" ]] && _notify_discord "$title" "$message" "$level"
    [[ -n "${PUSHOVER_USER:-}" && -n "${PUSHOVER_TOKEN:-}" ]] && _notify_pushover "$title" "$message" "$level"
    [[ -n "${NOTIFIARR_API_KEY:-}" ]] && _notify_notifiarr "$title" "$message" "$level"
    [[ -n "${EMAIL_TO:-}" ]] && _notify_email "$title" "$message" "$level"

    return 0
}

# Rate limiting: returns 0 if notification should be sent, 1 if throttled
# Requires NOTIFY_RATE_DIR to be set (defaults to /var/lib/watchdog)
_should_notify() {
    local service_name="${1:-default}"
    local rate_dir="${NOTIFY_RATE_DIR:-/var/lib/watchdog}"
    local rate_file="${rate_dir}/${service_name}.notify_ts"
    local min_interval="${NOTIFY_MIN_INTERVAL:-300}" # 5 minutes default
    local now
    now=$(date +%s)

    if [[ -f "$rate_file" ]]; then
        local last
        last=$(cat "$rate_file")
        if ((now - last < min_interval)); then
            _notify_log_warn "Notification throttled for $service_name (last sent $((now - last))s ago)"
            return 1
        fi
    fi

    mkdir -p "$rate_dir"
    echo "$now" >"$rate_file"
    return 0
}
