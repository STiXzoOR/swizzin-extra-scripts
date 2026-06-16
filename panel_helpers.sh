#!/bin/bash
set -euo pipefail
# Swizzin panel helper
# Defines: panel_register_app, panel_unregister_app

PLACEHOLDER_ICON_URL="https://raw.githubusercontent.com/swizzin/swizzin_dashboard/refs/heads/master/static/img/favicon/android-chrome-192x192.png"

# Ensure placeholder icon is available (called on demand, not at source-time)
_ensure_placeholder_icon() {
    # Icons must be in Swizzin's static directory for panel to find them
    local icons_dir="/opt/swizzin/static/img/apps"
    mkdir -p "$icons_dir"
    if [ ! -f "$icons_dir/placeholder.png" ]; then
        curl -fsSL "$PLACEHOLDER_ICON_URL" -o "$icons_dir/placeholder.png" >/dev/null 2>&1 || true
    fi
}

panel_register_app() {
    local name="$1"         # e.g. "seerr"
    local pretty_name="$2"  # e.g. "Seerr"
    local baseurl="$3"      # e.g. "/seerr" (or "" if using urloverride)
    local urloverride="$4"  # e.g. "https://seerr.example.com" or ""
    local systemd_name="$5" # e.g. "seerr"
    local img_name="$6"     # icon name (without .png)
    local icon_url="$7"     # optional: URL to PNG icon
    local check_systemd="${8:-true}"

    local profiles="/opt/swizzin/core/custom/profiles.py"
    # Icons must be in Swizzin's static directory for panel to find them
    local icons_dir="/opt/swizzin/static/img/apps"
    local classname="${name}_meta"

    # Panel not installed? bail quietly
    [ ! -f "$profiles" ] && return 0

    mkdir -p "$icons_dir"
    _ensure_placeholder_icon

    # Optional icon download
    if [ -n "$icon_url" ] && [ ! -f "$icons_dir/${img_name}.png" ]; then
        curl -fsSL "$icon_url" -o "$icons_dir/${img_name}.png" >/dev/null 2>&1 || true
    fi

    # Avoid duplicate class
    if ! grep -q "class ${classname}" "$profiles"; then
        {
            echo ""
            echo "class ${classname}:"
            echo "    name = \"${name}\""
            echo "    pretty_name = \"${pretty_name}\""
            if [ -n "$urloverride" ]; then
                echo "    urloverride = \"${urloverride}\""
            elif [ -n "$baseurl" ]; then
                echo "    baseurl = \"${baseurl}\""
            fi
            echo "    systemd = \"${systemd_name}\""
            echo "    img = \"${img_name}\""
            [ "$check_systemd" = "true" ] && echo "    check_theD = True"
        } >>"$profiles"
    fi

    # Try to restart panel to pick up changes (if present)
    systemctl restart panel >/dev/null 2>&1 || true
}

panel_unregister_app() {
    local name="$1"
    local profiles="/opt/swizzin/core/custom/profiles.py"
    local classname="${name}_meta"

    # Panel not installed? bail quietly
    [ ! -f "$profiles" ] && return 0

    # Remove the class block from profiles.py
    # This removes from "class <name>_meta:" until the next "class " or end of file
    if grep -q "class ${classname}" "$profiles"; then
        # Use sed to remove the class block
        sed -i "/^class ${classname}:/,/^class \|^$/{ /^class ${classname}:/d; /^class /!d; }" "$profiles" 2>/dev/null || true
        # Simpler approach: use Python to remove the class
        python3 - "$profiles" "$classname" <<'PYTHON' 2>/dev/null || true
import sys
import re

profiles_path = sys.argv[1]
classname = sys.argv[2]

with open(profiles_path, 'r') as f:
    content = f.read()

# Remove the class block (class name_meta: ... until next class or end)
pattern = rf'\n*class {classname}:.*?(?=\nclass |\Z)'
content = re.sub(pattern, '', content, flags=re.DOTALL)

with open(profiles_path, 'w') as f:
    f.write(content)
PYTHON
    fi

    # Try to restart panel to pick up changes
    systemctl restart panel >/dev/null 2>&1 || true
}
