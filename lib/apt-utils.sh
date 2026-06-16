#!/bin/bash
# ==============================================================================
# apt Utilities - Shared helper that makes Swizzin's apt_install safe under set -u
# ==============================================================================
# Source this file AFTER /etc/swizzin/sources/functions/utils from any script
# that uses `set -u` (or `set -euo pipefail`) and calls apt_install:
#
#   . /etc/swizzin/sources/globals.sh
#   . /etc/swizzin/sources/functions/utils
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true
#
# Why this exists:
#   Swizzin's `apt_install` delegates to `export -f`'d helpers
#   (_check_dpkg_lock, _apt_check, _apt_update) that reference unset variables
#   — $_apt_skip_checks, $_apt_ignore_errors, $_apt_install_recommends —
#   without default-value guards. Under `set -u`, these inherited functions
#   see the vars as unbound and abort with "unbound variable" even when the
#   caller has initialized (and exported) them. This is a known bash quirk
#   with `export -f` functions capturing scope at export time.
#
#   The quirk does not surface in most existing installers because their
#   app_reqs are already installed — apt_install short-circuits before
#   reaching _check_dpkg_lock. Any installer declaring a dep that isn't
#   already on the target system trips the failure mode.
#
# This helper overrides `apt_install` with a wrapper that toggles `set +u`
# for the duration of the swizzin call, then restores `-u`. Zero changes
# needed at call sites — existing `apt_install "${app_reqs[@]}"` lines
# continue to work and are now safe.
# ==============================================================================

# Save the original swizzin implementation so we can delegate to it.
if ! declare -f _swizzin_apt_install_original >/dev/null 2>&1 \
    && declare -f apt_install >/dev/null 2>&1; then
    eval "$(declare -f apt_install | sed '1s/apt_install/_swizzin_apt_install_original/')"
fi

apt_install() {
    local _prev_u_state="+u"
    [[ $- == *u* ]] && _prev_u_state="-u"
    set +u
    _swizzin_apt_install_original "$@"
    local rc=$?
    set "${_prev_u_state}"
    return $rc
}
export -f apt_install

# Same treatment for the other apt entry points swizzin exports.
if ! declare -f _swizzin_apt_update_original >/dev/null 2>&1 \
    && declare -f apt_update >/dev/null 2>&1; then
    eval "$(declare -f apt_update | sed '1s/apt_update/_swizzin_apt_update_original/')"
fi

apt_update() {
    local _prev_u_state="+u"
    [[ $- == *u* ]] && _prev_u_state="-u"
    set +u
    _swizzin_apt_update_original "$@"
    local rc=$?
    set "${_prev_u_state}"
    return $rc
}
export -f apt_update

if ! declare -f _swizzin_apt_upgrade_original >/dev/null 2>&1 \
    && declare -f apt_upgrade >/dev/null 2>&1; then
    eval "$(declare -f apt_upgrade | sed '1s/apt_upgrade/_swizzin_apt_upgrade_original/')"
fi

apt_upgrade() {
    local _prev_u_state="+u"
    [[ $- == *u* ]] && _prev_u_state="-u"
    set +u
    _swizzin_apt_upgrade_original "$@"
    local rc=$?
    set "${_prev_u_state}"
    return $rc
}
export -f apt_upgrade
