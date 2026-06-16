#!/bin/bash
# tailscale installer
# STiXzoOR 2026
# Usage: bash tailscale.sh [--update [--verbose]|--remove [--force]]
#
# Installs the official Tailscale package from pkgs.tailscale.com, enables the
# tailscaled daemon, and (optionally) joins the tailnet.
#
# Environment:
#   TS_AUTHKEY   If set, runs `tailscale up --authkey=$TS_AUTHKEY` for
#                unattended provisioning. Otherwise launches `tailscale up`
#                interactively and prints the login URL.
#   TS_HOSTNAME  Override the node name on the tailnet (default: $(hostname)-swizzin).
#   TS_EXTRA_UP_ARGS  Extra args appended to `tailscale up` (e.g. "--advertise-routes=10.0.0.0/24").
#
# Defaults applied to `tailscale up`:
#   --accept-dns=false   leave swizzin's DNS resolver alone
#   --ssh                enable Tailscale SSH

set -euo pipefail

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# App Configuration
# ==============================================================================
app_name="tailscale"
app_pretty="Tailscale"
app_lockname="${app_name//-/}"
app_servicefile="tailscaled.service"

app_keyring="/usr/share/keyrings/tailscale-archive-keyring.gpg"
app_aptlist="/etc/apt/sources.list.d/tailscale.list"

# ==============================================================================
# Cleanup trap
# ==============================================================================
_cleanup_needed=false
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

verbose=false
_verbose() { [[ "$verbose" == "true" ]] && echo_info "  $*"; }

# ==============================================================================
# Distro detection
# ==============================================================================
_detect_distro() {
    if [[ ! -r /etc/os-release ]]; then
        echo_error "Cannot read /etc/os-release"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-}"
    distro_codename="${VERSION_CODENAME:-}"
    if [[ -z "$distro_id" || -z "$distro_codename" ]]; then
        echo_error "Could not determine distro ID or codename from /etc/os-release"
        exit 1
    fi
    case "$distro_id" in
        ubuntu | debian) ;;
        *)
            echo_error "Unsupported distro '${distro_id}'. tailscale.sh supports Ubuntu and Debian only."
            exit 1
            ;;
    esac
}

# ==============================================================================
# Install
# ==============================================================================
_install_tailscale() {
    _detect_distro

    echo_progress_start "Adding Tailscale apt repository (${distro_id}/${distro_codename})"
    local keyring_url="https://pkgs.tailscale.com/stable/${distro_id}/${distro_codename}.noarmor.gpg"
    local list_url="https://pkgs.tailscale.com/stable/${distro_id}/${distro_codename}.tailscale-keyring.list"

    if ! curl -fsSL "$keyring_url" -o "$app_keyring" >>"$log" 2>&1; then
        echo_error "Failed to download Tailscale keyring from ${keyring_url}"
        exit 1
    fi
    if ! curl -fsSL "$list_url" -o "$app_aptlist" >>"$log" 2>&1; then
        echo_error "Failed to download Tailscale apt list from ${list_url}"
        exit 1
    fi
    echo_progress_done "Repository configured"

    echo_progress_start "Installing tailscale package"
    apt_update >>"$log" 2>&1
    apt_install tailscale
    echo_progress_done "Package installed"

    echo_progress_start "Enabling tailscaled service"
    systemctl enable --now "$app_servicefile" >>"$log" 2>&1
    echo_progress_done "tailscaled active"
}

# ==============================================================================
# tailscale up — auth flow
# ==============================================================================
_tailscale_up() {
    local hostname="${TS_HOSTNAME:-$(hostname)-swizzin}"
    local extra_args="${TS_EXTRA_UP_ARGS:-}"

    # Already authed? Skip.
    if tailscale status >/dev/null 2>&1; then
        echo_info "Tailscale is already authenticated ($(tailscale status --self --peers=false 2>/dev/null | awk 'NR==1 {print $2}'))"
        return 0
    fi

    if [[ -n "${TS_AUTHKEY:-}" ]]; then
        echo_progress_start "Authenticating with TS_AUTHKEY"
        # shellcheck disable=SC2086
        if tailscale up \
            --authkey="$TS_AUTHKEY" \
            --hostname="$hostname" \
            --accept-dns=false \
            --ssh \
            $extra_args >>"$log" 2>&1; then
            echo_progress_done "Joined tailnet as ${hostname}"
        else
            echo_error "tailscale up --authkey failed; check $log"
            exit 1
        fi
        return 0
    fi

    # Interactive: print the URL and let the operator click through
    echo_info "TS_AUTHKEY not set — interactive auth required"
    echo_info "Open the URL printed below in a browser to add this node to your tailnet"
    # shellcheck disable=SC2086
    tailscale up \
        --hostname="$hostname" \
        --accept-dns=false \
        --ssh \
        $extra_args
}

# ==============================================================================
# Update
# ==============================================================================
_update_tailscale() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    echo_info "Updating ${app_pretty}..."
    echo_progress_start "Refreshing apt indexes"
    apt_update >>"$log" 2>&1
    echo_progress_done "Indexes refreshed"

    echo_progress_start "Upgrading tailscale package"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade tailscale >>"$log" 2>&1
    echo_progress_done "Upgrade complete"

    _verbose "Restarting tailscaled"
    systemctl restart "$app_servicefile"
    sleep 2
    if systemctl is-active --quiet "$app_servicefile"; then
        echo_success "${app_pretty} updated ($(tailscale version | head -1))"
    else
        echo_error "tailscaled failed to restart after upgrade"
        exit 1
    fi
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_tailscale() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    if ask "Log out of the tailnet first (tailscale logout)?" Y; then
        tailscale logout 2>/dev/null || true
    fi

    echo_progress_start "Stopping and disabling tailscaled"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    echo_progress_done "Service stopped"

    echo_progress_start "Purging tailscale package"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y tailscale tailscale-archive-keyring >>"$log" 2>&1 || true
    echo_progress_done "Package purged"

    echo_progress_start "Removing repository files"
    rm -f "$app_keyring" "$app_aptlist"
    apt_update >>"$log" 2>&1 || true
    echo_progress_done "Repository removed"

    if ask "Also remove /var/lib/tailscale (node identity, ACL state)?" N; then
        rm -rf /var/lib/tailscale
        echo_info "/var/lib/tailscale removed"
    else
        echo_info "/var/lib/tailscale preserved — re-joining the tailnet later will reuse the existing node identity"
    fi

    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Main
# ==============================================================================
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

case "${1:-}" in
    --remove)
        _remove_tailscale "${2:-}"
        ;;
    --update)
        _update_tailscale
        ;;
esac

# Adopt an existing install rather than refusing it — common when the box has
# tailscale from a manual install and we want the lock file in sync.
if command -v tailscale >/dev/null 2>&1 && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "tailscale binary already present; adopting existing install"
    systemctl enable --now "$app_servicefile" >>"$log" 2>&1 || true
    _tailscale_up
    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
    echo_success "${app_pretty} adopted ($(tailscale version | head -1))"
    exit 0
fi

if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_error "${app_pretty} is already installed"
    exit 1
fi

_cleanup_needed=true

_install_tailscale
_tailscale_up

touch "/install/.${app_lockname}.lock"
_lock_file_created="/install/.${app_lockname}.lock"
_cleanup_needed=false

echo_success "${app_pretty} installed ($(tailscale version | head -1))"
echo_info "Status: tailscale status"
echo_info "Admin: https://login.tailscale.com/admin/machines"
