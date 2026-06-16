#!/bin/bash
# Shared debrid provider prompting for Docker installers
# Used by: stremthru.sh, mediafusion.sh

_VALID_DEBRID_PROVIDERS="realdebrid alldebrid torbox premiumize offcloud debridlink easydebrid"

# Validate a debrid provider name
# Args: $1=provider name
# Returns 0 if valid, 1 if not
_validate_debrid_provider() {
    local provider="$1"
    local p
    for p in $_VALID_DEBRID_PROVIDERS; do
        [[ "$p" == "$provider" ]] && return 0
    done
    return 1
}

# Prompt for debrid provider and API key
# Sets: debrid_provider, debrid_key
# Supports env var override: $1_PROVIDER and $1_API_KEY (prefix passed as $1)
# Args: $1=env_var_prefix (e.g., "STREMTHRU" or "MEDIAFUSION")
#       $2=compose_file (optional, for re-run detection)
#       $3=compose_marker (optional, env var name to check for existing config)
_prompt_debrid_provider() {
    local env_prefix="$1"
    local compose_file="${2:-}"
    local compose_marker="${3:-}"

    local env_provider_var="${env_prefix}_PROVIDER"
    local env_key_var="${env_prefix}_API_KEY"

    debrid_provider=""
    debrid_key=""

    # Check env vars first (unattended install)
    if [[ -n "${!env_provider_var:-}" && -n "${!env_key_var:-}" ]]; then
        debrid_provider="${!env_provider_var}"
        debrid_key="${!env_key_var}"
        if ! _validate_debrid_provider "$debrid_provider"; then
            echo_error "Unknown debrid provider: ${debrid_provider}"
            echo_info "Valid providers: ${_VALID_DEBRID_PROVIDERS}"
            exit 1
        fi
        echo_info "Using debrid provider from environment: ${debrid_provider}"
        return
    fi

    # Check for existing config (re-run protection)
    if [[ -n "$compose_file" && -n "$compose_marker" ]] \
        && [[ -f "$compose_file" ]] \
        && grep -q "$compose_marker" "$compose_file" 2>/dev/null; then
        echo_info "Debrid credentials already configured, keeping existing"
        return 1
    fi

    echo_info "Supported providers: ${_VALID_DEBRID_PROVIDERS}"
    echo_query "Enter debrid provider name:" ""
    read -r debrid_provider </dev/tty

    if ! _validate_debrid_provider "$debrid_provider"; then
        echo_error "Unknown provider: ${debrid_provider}"
        echo_info "Valid providers: ${_VALID_DEBRID_PROVIDERS}"
        exit 1
    fi

    echo_query "Enter your ${debrid_provider} API key:" ""
    read -rs debrid_key </dev/tty
    echo "" # newline after silent read

    if [[ -z "$debrid_key" ]]; then
        echo_error "API key cannot be empty"
        exit 1
    fi

    # Validate API key characters (prevent YAML injection in compose files)
    if [[ ! "$debrid_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo_error "API key contains invalid characters (only A-Z, a-z, 0-9, _, - allowed)"
        exit 1
    fi
}
