#!/bin/bash
# Shared Prowlarr auto-configuration for Torznab indexers
# Used by: zilean.sh, stremthru.sh, mediafusion.sh

# Discover Prowlarr installation and read config
# Sets: PROWLARR_API, PROWLARR_PORT, PROWLARR_BASE
# Returns 1 if not found
_discover_prowlarr() {
    if [[ ! -f /install/.prowlarr.lock ]]; then
        return 1
    fi

    PROWLARR_API=""
    PROWLARR_PORT=""
    PROWLARR_BASE=""

    local cfg
    for cfg in /home/*/.config/Prowlarr/config.xml; do
        [[ -f "$cfg" ]] || continue
        PROWLARR_API=$(grep -oP '<ApiKey>\K[^<]+' "$cfg" 2>/dev/null) || true
        PROWLARR_PORT=$(grep -oP '<Port>\K[^<]+' "$cfg" 2>/dev/null) || true
        PROWLARR_BASE=$(grep -oP '<UrlBase>\K[^<]+' "$cfg" 2>/dev/null) || true
        break
    done

    if [[ -z "${PROWLARR_API:-}" || -z "${PROWLARR_PORT:-}" ]]; then
        return 1
    fi
}

# Add a Generic Torznab indexer to Prowlarr
# Args: $1=name, $2=torznab_url, $3=api_key (optional)
_add_prowlarr_torznab() {
    local name="$1"
    local url="$2"
    local api_key="${3:-}"

    local prowlarr_url="http://127.0.0.1:${PROWLARR_PORT}"
    [[ -n "${PROWLARR_BASE:-}" ]] && prowlarr_url="${prowlarr_url}/${PROWLARR_BASE#/}"

    echo_progress_start "Adding ${name} to Prowlarr"

    local payload
    payload=$(cat <<JSONEOF
{
  "name": "${name}",
  "implementation": "Torznab",
  "implementationName": "Torznab",
  "configContract": "TorznabSettings",
  "protocol": "torrent",
  "enable": true,
  "fields": [
    {"name": "baseUrl", "value": "${url}"},
    {"name": "apiPath", "value": ""},
    {"name": "apiKey", "value": "${api_key}"},
    {"name": "minimumSeeders", "value": 0}
  ],
  "tags": []
}
JSONEOF
    )

    local response_body http_code
    response_body=$(mktemp)
    http_code=$(curl --config <(printf 'header = "X-Api-Key: %s"' "$PROWLARR_API") \
        -s -o "$response_body" -w '%{http_code}' \
        -X POST "${prowlarr_url}/api/v1/indexer" \
        -H "Content-Type: application/json" \
        -d "$payload") || true

    if [[ "$http_code" == "201" ]]; then
        rm -f "$response_body"
        echo_progress_done "${name} added to Prowlarr"
        return 0
    else
        echo_warn "Could not auto-configure Prowlarr (HTTP ${http_code})"
        # Log response for debugging
        if [[ -s "$response_body" ]]; then
            echo_info "Prowlarr API response: $(cat "$response_body")"
        fi
        rm -f "$response_body"
        return 1
    fi
}

# Display manual Prowlarr Torznab setup instructions
# Args: $1=name, $2=torznab_url, $3=notes (optional)
_display_prowlarr_torznab_info() {
    local name="$1"
    local url="$2"
    local notes="${3:-}"

    echo ""
    echo_info "=== Prowlarr Setup ==="
    echo_info "Add ${name} as a Generic Torznab indexer in Prowlarr:"
    echo_info "  URL: ${url}"
    if [[ -n "$notes" ]]; then
        echo_info "  ${notes}"
    fi
    echo ""
}
