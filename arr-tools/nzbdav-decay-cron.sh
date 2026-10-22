#!/usr/bin/env bash
# Weekly usenet-availability audit of the 4K library.
#
# Runs nzbdav-decay-check and notifies only when something needs attention.
# Article availability decays silently: nzbdav verifies at grab time and
# `repair.enable=false` means nothing re-checks, so a healthy import can rot
# down to one provider (or none) and only show up as buffering mid-film.
#
# Installed by /etc/cron.d/nzbdav-decay-check.
set -uo pipefail

MIN_SIZE="${MIN_SIZE:-40}"          # GiB; below this, bitrate is low enough that one provider copes
RECHECK_DAYS="${RECHECK_DAYS:-6}"   # < the 7d cron period, so each run re-checks everything
CHECK_BIN="/usr/local/bin/nzbdav-decay-check"
LOG="/var/log/nzbdav-decay-check.log"
JSON="/var/log/nzbdav-decay-latest.json"
STATE_DIR="/var/lib/nzbdav-decay-check"

mkdir -p "$STATE_DIR"

_log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }
_notify_log_warn() { _log "WARN: $1"; }

# Notifications are optional; no-op cleanly if the lib or config is missing.
_nlib="/opt/swizzin-extras/lib/notifications.sh"
[[ -f "$_nlib" ]] || _nlib="/usr/local/lib/swizzin/notifications.sh"
if [[ -f "$_nlib" ]]; then
    # shellcheck source=/dev/null
    . "$_nlib"
    NOTIFY_RATE_DIR="$STATE_DIR"
    NOTIFY_MIN_INTERVAL="${NOTIFY_MIN_INTERVAL:-79200}"   # 22h: at most one per daily-ish run
    [[ -f /opt/swizzin-extras/watchdog.conf ]] && . /opt/swizzin-extras/watchdog.conf
else
    _notify() { :; }
    _should_notify() { return 0; }
fi
unset _nlib

if [[ ! -x "$CHECK_BIN" ]]; then
    _log "ERROR: $CHECK_BIN not found or not executable"
    exit 2
fi

_log "=== decay check start (min-size=${MIN_SIZE}GiB recheck=${RECHECK_DAYS}d) ==="
out=$("$CHECK_BIN" --min-size "$MIN_SIZE" --recheck-days "$RECHECK_DAYS" --json "$JSON" 2>&1)
rc=$?
printf '%s\n' "$out" >>"$LOG"
_log "=== decay check end (rc=$rc) ==="

# rc 2 = the tool itself failed; worth a shout since the audit silently stopped.
if ((rc == 2)); then
    if _should_notify "nzbdav-decay-error"; then
        _notify "nzbdav decay check FAILED" "$(printf '%s' "$out" | tail -5)" "error"
    fi
    exit 2
fi

((rc == 0)) && { _log "nothing flagged"; exit 0; }

# rc 1: build a short summary from the JSON rather than dumping the whole run.
summary=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"could not read report: {exc}")
    raise SystemExit

counts = {}
for r in rows:
    counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
head = "  ".join(f"{v}:{counts[v]}" for v in ("DEAD", "HOLES", "RISK", "THIN", "OK") if counts.get(v))
print(head)

# Only DEAD/HOLES/RISK are actionable; THIN still has two complete providers.
bad = [r for r in rows if r["verdict"] in ("DEAD", "HOLES", "RISK")]
bad.sort(key=lambda r: (r["verdict"] != "DEAD", r["verdict"] != "HOLES", -r["size_gib"]))
for r in bad[:12]:
    print(f"[{r['verdict']}] {r['size_gib']:.0f}G {r['title'][:52]}")
if len(bad) > 12:
    print(f"...and {len(bad)-12} more (see {sys.argv[1]})")
PY
)

_log "flagged:"$'\n'"$summary"
if _should_notify "nzbdav-decay"; then
    _notify "nzbdav: 4K availability decayed" "$summary" "warning"
fi
exit 1
