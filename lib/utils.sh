#!/bin/bash
# ==============================================================================
# Shared Utilities - General helper functions for swizzin scripts
# ==============================================================================
# Source this file from scripts that need these helpers:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true
#
# Provides:
#   port (override)    - SIGPIPE-safe replacement for Swizzin's port()
#   swizdb (override)  - set -u safe replacement for Swizzin's swizdb()
#   _sed_escape_value  - Escape a string for safe use in sed replacement
# ==============================================================================

# Override Swizzin's port() to avoid SIGPIPE under set -o pipefail.
# Upstream uses `shuf | head -n 1` which triggers broken pipe errors.
# Fix: use `shuf -n 1` to pick one random line without a pipe.
port() {
    comm -23 \
        <(seq "$1" "$2" | sort) \
        <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) \
        | shuf -n 1
}

# Override Swizzin's swizdb() to avoid "unbound variable" under set -u.
# Upstream unconditionally assigns value="$3", which blows up when called
# with only 2 args (e.g. "swizdb get key").
swizdb() {
    local method="$1"
    local key="$2"
    local value="${3:-}"

    case "$method" in
        set) _setswizdb "$key" "$value" ;;
        get) _getswizdb "$key" ;;
        clear) _clearswizdb "$key" ;;
        path) _pathswizdb "$key" ;;
        list) _listswizdb "$key" ;;
        *)
            echo_error "Unsupported db method!"
            return 1
            ;;
    esac
}

# Escape a string for safe use in sed replacement (right-hand side of s|...|...|)
# Handles: & (backreference), \ (escape char), | (delimiter), newlines
# Usage: sed -i "s|pattern|$(_sed_escape_value "$value")|" file
_sed_escape_value() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}
