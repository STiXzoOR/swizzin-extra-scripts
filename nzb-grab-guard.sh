#!/bin/bash
# nzb-grab-guard installer
# Local proxy in front of NZBHydra2 that stops *arr grab loops from reaching
# the indexers: successful NZBs are served from a local cache on repeat,
# failed releases are answered with 404 locally instead of being retried.
#
# Usage:
#   bash nzb-grab-guard.sh            # install/update + enable + start
#   bash nzb-grab-guard.sh --wire     # point Prowlarr's NZBHydra2 indexer at the guard
#   bash nzb-grab-guard.sh --unwire   # point it back at Hydra directly
#   bash nzb-grab-guard.sh --status   # service status + recent activity
#   bash nzb-grab-guard.sh --remove   # unwire + full uninstall

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nzb-grab-guard.py"
SCRIPT_DST="/usr/local/bin/nzb-grab-guard.py"
SERVICE_NAME="nzb-grab-guard"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="${SERVICE_USER:-}"
GUARD_HOST="${GUARD_HOST:-127.0.0.1}"
GUARD_PORT="${GUARD_PORT:-11022}"
HYDRA_URL="${HYDRA_URL:-http://127.0.0.1:11021}"
GUARD_URL="http://${GUARD_HOST}:${GUARD_PORT}"
RESERVED_PORTS_CONF="/etc/sysctl.d/99-zzz-reserved-service-ports.conf"
NOTIFY_CONF="/opt/swizzin-extras/watchdog.conf"

# ==============================================================================
# Helpers
# ==============================================================================

echo_info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
echo_ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
echo_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
echo_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# Pick the first home dir that owns a Prowlarr config; fall back to the swizzin master user.
_pick_user() {
    [[ -n "$SERVICE_USER" ]] && { echo "$SERVICE_USER"; return; }
    for d in /home/*/; do
        [[ -d "${d}.config/Prowlarr" ]] || continue
        basename "$d"
        return
    done
    if [[ -f /etc/swizzin/sources/functions/utils ]]; then
        # shellcheck source=/dev/null
        . /etc/swizzin/sources/functions/utils
        _get_master_username
        return
    fi
    echo "root"
}

# Keep the guard's port out of the ephemeral range so an outbound socket can't steal it.
_reserve_port() {
    [[ -f "$RESERVED_PORTS_CONF" ]] || return 0
    if grep -qE "(=|,| )${GUARD_PORT}(,|$)" "$RESERVED_PORTS_CONF"; then
        return 0
    fi
    sed -i -E "s/^(net\.ipv4\.ip_local_reserved_ports *= *.*)$/\1,${GUARD_PORT}/" "$RESERVED_PORTS_CONF"
    sysctl -q -p "$RESERVED_PORTS_CONF" >/dev/null
    echo_ok "Reserved port ${GUARD_PORT} in ${RESERVED_PORTS_CONF##*/}"
}

# ==============================================================================
# Cleanup Trap (rollback partial install)
# ==============================================================================
_cleanup_needed=false
_unit_written=""
_script_written=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_unit_written" ]] && {
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$_unit_written"
            systemctl daemon-reload
        }
        [[ -n "$_script_written" ]] && rm -f "$_script_written"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Install
# ==============================================================================

_write_unit() {
    local svc_user="$1" cred_line=""
    # Root-only notification channel config, handed to the unprivileged user read-only.
    [[ -f "$NOTIFY_CONF" ]] && cred_line="LoadCredential=watchdog.conf:${NOTIFY_CONF}"$'\n'
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=NZB grab-loop guard in front of NZBHydra2 (caches NZBs, blocks repeat grabs of failed releases)
Documentation=https://github.com/STiXzoOR/swizzin-scripts/blob/main/nzb-grab-guard.sh
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${svc_user}
Group=${svc_user}
Environment=GUARD_HOST=${GUARD_HOST}
Environment=GUARD_PORT=${GUARD_PORT}
Environment=GUARD_UPSTREAM=${HYDRA_URL}
StateDirectory=${SERVICE_NAME}
${cred_line}ExecStart=/usr/bin/python3 ${SCRIPT_DST}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Hardening
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
}

_install() {
    echo_info "Installing nzb-grab-guard..."

    if [[ ! -f "$SCRIPT_SRC" ]]; then
        echo_error "Source script not found: $SCRIPT_SRC"
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo_error "python3 is required but not installed"
        exit 1
    fi

    local svc_user
    svc_user=$(_pick_user)
    if ! id "$svc_user" >/dev/null 2>&1; then
        echo_error "Service user '$svc_user' does not exist"
        exit 1
    fi
    echo_ok "Using service user: $svc_user"

    if ss -tlnp 2>/dev/null | grep -q ":${GUARD_PORT} " && ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo_error "Port ${GUARD_PORT} is in use by another process — set GUARD_PORT to override"
        exit 1
    fi

    _cleanup_needed=true

    cp "$SCRIPT_SRC" "$SCRIPT_DST"
    chmod 0755 "$SCRIPT_DST"
    _script_written="$SCRIPT_DST"
    echo_ok "Script deployed to $SCRIPT_DST"

    _write_unit "$svc_user"
    _unit_written="$SERVICE_FILE"
    echo_ok "Service unit created at $SERVICE_FILE"

    _reserve_port

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    sleep 2

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo_error "Service failed to start"
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi
    echo_ok "Service started"

    local code
    code=$(curl -sS -m 15 -o /dev/null -w "%{http_code}" "${GUARD_URL}/" 2>/dev/null || true)
    if [[ "$code" == "000" || "$code" == "502" ]]; then
        echo_warn "Smoke test got HTTP $code — is Hydra reachable at ${HYDRA_URL}?"
    else
        echo_ok "Smoke test: Hydra answered through the guard (HTTP $code)"
    fi

    _cleanup_needed=false

    cat <<EOF

$(echo_ok "Installation complete!")

Route Prowlarr's NZBHydra2 indexer through the guard:
  bash $0 --wire

EOF
}

# ==============================================================================
# Repoint Prowlarr's Hydra indexer  (--wire / --unwire)
# ==============================================================================

_wire() {
    local from="$1" to="$2"
    python3 - "$from" "$to" <<'PY'
import json, sys, urllib.request, urllib.error, xml.etree.ElementTree as ET
from pathlib import Path

FROM, TO = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/")

def call(method, url, apikey, body=None):
    req = urllib.request.Request(url, method=method, headers={"X-Api-Key": apikey})
    data = None
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

changed = 0
for xml in Path("/home").glob("*/.config/Prowlarr/config.xml"):
    root = ET.parse(xml).getroot()
    port, apikey = root.findtext("Port"), root.findtext("ApiKey")
    urlbase = (root.findtext("UrlBase") or "").strip("/")
    base = f"http://127.0.0.1:{port}" + (f"/{urlbase}" if urlbase else "") + "/api/v1/indexer"
    status, raw = call("GET", base, apikey)
    if status != 200:
        print(f"  [{xml}] could not list indexers (HTTP {status})")
        continue
    for idx in json.loads(raw):
        if idx.get("protocol") != "usenet":
            continue
        for f in idx.get("fields", []):
            if f.get("name") == "baseUrl" and isinstance(f.get("value"), str) \
                    and f["value"].rstrip("/") == FROM:
                f["value"] = TO
                st, body = call("PUT", f"{base}/{idx['id']}", apikey, idx)
                ok = 200 <= st < 300
                print(f"  {idx['name']} (id={idx['id']}): {FROM} -> {TO} "
                      + ("OK" if ok else f"FAIL HTTP {st} {body[:200]!r}"))
                changed += ok
print(f"Updated {changed} indexer(s)")
sys.exit(0 if changed else 1)
PY
}

# ==============================================================================
# Remove
# ==============================================================================

_remove() {
    echo_info "Removing nzb-grab-guard..."
    _wire "$GUARD_URL" "$HYDRA_URL" || echo_warn "No Prowlarr indexer was pointing at the guard"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$SCRIPT_DST"
    rm -rf "/var/lib/${SERVICE_NAME}"
    echo_ok "Removal complete"
}

# ==============================================================================
# Status
# ==============================================================================

_status() {
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo
    echo_info "Recent grabs / loops:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 30 | grep -E 'GRAB|LOOP|listening' || true
}

# ==============================================================================
# Main
# ==============================================================================

case "${1:-}" in
    --wire)
        systemctl is-active --quiet "$SERVICE_NAME" || { echo_error "Service is not running — install first"; exit 1; }
        _wire "$HYDRA_URL" "$GUARD_URL"
        ;;
    --unwire)
        _wire "$GUARD_URL" "$HYDRA_URL"
        ;;
    --remove)
        _remove
        ;;
    --status)
        _status
        ;;
    "")
        if systemctl list-unit-files "${SERVICE_NAME}.service" 2>/dev/null | grep -q "${SERVICE_NAME}.service"; then
            echo_info "Already installed. Updating script and restarting..."
            cp "$SCRIPT_SRC" "$SCRIPT_DST"
            chmod 0755 "$SCRIPT_DST"
            _write_unit "$(systemctl show -p User --value "$SERVICE_NAME")"
            systemctl daemon-reload
            systemctl restart "$SERVICE_NAME"
            sleep 2
            systemctl is-active --quiet "$SERVICE_NAME" && echo_ok "Restarted" || {
                echo_error "Service failed to restart"
                journalctl -u "$SERVICE_NAME" --no-pager -n 20
                exit 1
            }
        else
            _install
        fi
        ;;
    *)
        echo "Usage: $0 [--wire | --unwire | --status | --remove]"
        exit 2
        ;;
esac
