# Coding Standards

## Bracket Style

Always use Bash `[[ ]]` for conditionals:

```bash
# Correct
if [[ -f "$file" ]]; then
if [[ -n "$var" ]]; then

# Incorrect - do not use single brackets
if [ -f "$file" ]; then
```

## Variable Quoting

Always quote variables and use braces for clarity:

```bash
# Correct
touch "$log"
chown "${user}:${user}" "$config_dir"
mkdir -p "${app_dir}/${app_name}"

# Incorrect
touch $log
chown $user:$user $config_dir
```

## Confirmations

Use Swizzin's `ask` function for yes/no prompts:

```bash
if ask "Would you like to purge the configuration?" N; then
    rm -rf "$config_dir"
fi
```

## Error Handling

Every script uses strict mode:

```bash
set -euo pipefail
```

### Positional Parameter Guards

Under `set -u`, unset variables cause immediate abort. Always use default values:

```bash
case "${1:-}" in       # Not "$1"
    "--remove")
        _remove "${2:-}"   # Not "$2"
        ;;
esac
```

### Arithmetic Safety

`(( expr ))` returns exit 1 when the result is 0, which triggers `set -e`. Use `|| true`:

```bash
((count++)) || true
```

### Commands That May Fail

Use `|| true` for commands that legitimately return non-zero (e.g., grep with no matches, stopping already-stopped services):

```bash
systemctl stop "$service" 2>/dev/null || true    # Service may not exist
count=$(grep -c "pattern" file.txt || true)       # No matches = exit 1
```

## Cleanup Trap Handlers

Template scripts include trap handlers that clean up on failure:

```bash
_cleanup_needed=false

cleanup() {
    local exit_code=$?
    [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]] || return 0
    echo_error "Installation failed (exit code: $exit_code). Cleaning up..."
    # Remove partial artifacts
}

trap cleanup EXIT
trap '' PIPE
```

Set `_cleanup_needed=true` before the install starts and `_cleanup_needed=false` after success.

## Script Header

Every script starts with:

```bash
#!/bin/bash
# <appname> installer
# STiXzoOR 2026
# Usage: bash <appname>.sh [--remove [--force]|--register-panel]

set -euo pipefail

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

## Panel Helper Loading

Use the local-first pattern (no remote download):

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
    if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
        . "${SCRIPT_DIR}/panel_helpers.sh"
        return
    fi
    if [[ -f "$PANEL_HELPER_CACHE" ]]; then
        . "$PANEL_HELPER_CACHE"
        return
    fi
    echo_info "panel_helpers.sh not found; skipping panel integration"
}
```

The panel helper is loaded from the local repo first, then from the cache. There is no GitHub download fallback (supply chain security).

## Sed Injection Prevention

When using `sed` with user-supplied values, escape special characters:

```bash
# Source the shared utility
. "${SCRIPT_DIR}/lib/utils.sh"

# Escape before use in sed replacement
local escaped_value
escaped_value=$(_sed_escape_value "$user_input")
sed -i "s|^key=.*|key=\"${escaped_value}\"|" "$config_file"
```

## Temporary Files

Use `mktemp` instead of hardcoded `/tmp` paths to prevent symlink attacks:

```bash
_tmp_download=$(mktemp /tmp/myapp-XXXXXX.tar.gz)
_tmp_extract=$(mktemp -d /tmp/myapp-extract-XXXXXX)
```

## Config Overwrite Guards

Protect user customizations on re-run:

```bash
if [[ ! -f "$config_file" ]]; then
    cat >"$config_file" <<EOF
# Default configuration
EOF
else
    echo_info "Existing config found at $config_file, not overwriting"
fi
# Always fix ownership (outside the guard)
chown "${user}:${user}" "$config_file"
```

## Nginx Reload

Always validate before reloading:

```bash
# Source the shared utility
. "${SCRIPT_DIR}/lib/nginx-utils.sh"

# Use instead of bare systemctl reload nginx
_reload_nginx
```

In removal paths, continue to use `systemctl reload nginx 2>/dev/null || true`.

## Credential Security

Hide API keys from process listings (`ps aux`):

```bash
# Use curl --config with process substitution
curl --config <(printf 'header = "Authorization: token %s"' "$token") "$url"
```

## File Permissions

Config files containing credentials must be locked down:

```bash
chmod 600 "$config_file"    # Owner read/write only
chmod 750 "$config_dir"     # Owner rwx, group rx
```

## Lock File Handling

Check before install, create after success:

```bash
# At start of install
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_error "${app_name} is already installed"
    exit 1
fi

# At end of successful install
touch "/install/.${app_lockname}.lock"
```
