#!/bin/bash
# ==============================================================================
# Nginx Utilities - Shared helper functions for nginx management
# ==============================================================================
# Source this file from scripts that need to reload nginx:
#   . "${SCRIPT_DIR}/lib/nginx-utils.sh" 2>/dev/null || true
#
# Provides:
#   _reload_nginx  - Validate config then reload (returns 1 on failure)
# ==============================================================================

# Remove an app's nginx config and its organizr-apps.conf reference
# Usage: _remove_nginx_conf "app_name"
# Call _reload_nginx separately after this
_remove_nginx_conf() {
    local conf_name="$1"
    local apps_include="/etc/nginx/snippets/organizr-apps.conf"

    # Remove from organizr-apps.conf if present (prevents stale includes)
    if [ -f "$apps_include" ]; then
        sed -i "\|include /etc/nginx/apps/${conf_name}.conf;|d" "$apps_include"
    fi

    rm -f "/etc/nginx/apps/${conf_name}.conf"
}

_reload_nginx() {
    if [[ -f /install/.nginx.lock ]]; then
        local test_output
        if test_output=$(nginx -t 2>&1); then
            systemctl reload nginx
        else
            echo_error "Nginx configuration test failed:"
            echo_error "$test_output"
            return 1
        fi
    fi
}
