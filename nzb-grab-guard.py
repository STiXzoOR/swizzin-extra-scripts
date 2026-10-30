#!/usr/bin/env python3
"""
Grab-loop guard in front of NZBHydra2.

Every usenet indexer is reached through Hydra, so Hydra's NZB download
endpoint is the one place every grab passes through. Any *arr bug that
re-grabs the same release (stuck pending releases, quality-enforcement
loops, download-client re-adds) ends up as the same Hydra release id
being fetched over and over -- which indexers treat as abuse and answer
by flagging or rate-limiting the account.

This proxy forwards everything to Hydra unchanged, except NZB downloads:

  * success  -> the NZB is cached on disk and served locally for
                GUARD_SUCCESS_TTL; the indexer sees exactly one grab.
  * failure  -> remembered for GUARD_FAILURE_TTL; repeats are answered
                with 404 locally, without touching Hydra or the indexer.

Upstream failures are always returned as 404. Sonarr/Radarr treat a 404
as "release no longer available" and move on to the next release; any
other status counts as an indexer failure, and enough of those put the
whole Hydra indexer (every backend at once) into a 24h backoff.

Hydra builds its result links from the request Host header, so pointing
Prowlarr's Hydra base URL at this proxy routes every grab through it.

Env:
    GUARD_HOST           bind host, default 127.0.0.1
    GUARD_PORT           bind port, default 11022
    GUARD_UPSTREAM       Hydra base, default http://127.0.0.1:11021
    GUARD_STATE_DIR      sqlite + NZB cache, default $STATE_DIRECTORY or /var/lib/nzb-grab-guard
    GUARD_SUCCESS_TTL    seconds to serve a cached NZB, default 604800 (7d)
    GUARD_FAILURE_TTL    seconds to block a failed release, default 86400 (24h)
    GUARD_LOOP_ALERT     absorbed repeats per release per day before alerting, default 10
    GUARD_NOTIFY_LIB     notification library, default /opt/swizzin-extras/lib/notifications.sh
    GUARD_NOTIFY_CONF    channel config (DISCORD_WEBHOOK, PUSHOVER_*, ...), default
                         $CREDENTIALS_DIRECTORY/watchdog.conf (systemd LoadCredential of
                         the root-only /opt/swizzin-extras/watchdog.conf)
"""

import hashlib
import http.client
import os
import re
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

HOST = os.environ.get("GUARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("GUARD_PORT", "11022"))
UPSTREAM = urlsplit(os.environ.get("GUARD_UPSTREAM", "http://127.0.0.1:11021"))
STATE_DIR = Path(os.environ.get("GUARD_STATE_DIR") or os.environ.get("STATE_DIRECTORY") or "/var/lib/nzb-grab-guard")
SUCCESS_TTL = int(os.environ.get("GUARD_SUCCESS_TTL", "604800"))
FAILURE_TTL = int(os.environ.get("GUARD_FAILURE_TTL", "86400"))
LOOP_ALERT = int(os.environ.get("GUARD_LOOP_ALERT", "10"))
NOTIFY_LIB = os.environ.get("GUARD_NOTIFY_LIB", "/opt/swizzin-extras/lib/notifications.sh")
NOTIFY_CONF = os.environ.get("GUARD_NOTIFY_CONF") or os.path.join(
    os.environ.get("CREDENTIALS_DIRECTORY", "/opt/swizzin-extras"), "watchdog.conf")
TIMEOUT = 120

# Hydra: /<base>/getnzb/api/<id>[.<suffix>] (newznab links) and /<base>/getnzb/user/<id> (UI);
# newznab-style t=get&id=<id> on /<base>/api is covered too.
_GETNZB_RE = re.compile(r"/getnzb/(?:api|user)/(-?\d+)")
# Response headers worth replaying from a cached NZB (filename, DNZB metadata).
_KEEP_HEADERS = ("content-type", "content-disposition")
_HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
                "proxy-authorization", "proxy-authenticate"}

NZB_DIR = STATE_DIR / "nzb"
_db_lock = threading.Lock()
_id_locks: dict[str, threading.Lock] = {}
_id_locks_lock = threading.Lock()


def log(msg: str) -> None:
    sys.stderr.write(f"[{time.strftime('%F %T')}] {msg}\n")


def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(STATE_DIR / "guard.db", timeout=30, check_same_thread=False)
    conn.execute("""CREATE TABLE IF NOT EXISTS releases (
        rid TEXT PRIMARY KEY,
        status TEXT NOT NULL,          -- 'ok' | 'failed'
        expires REAL NOT NULL,
        key_hash TEXT NOT NULL,        -- sha256 of the apikey that fetched it
        headers TEXT NOT NULL DEFAULT '',
        upstream_status INTEGER,
        title TEXT NOT NULL DEFAULT '',
        absorbed INTEGER NOT NULL DEFAULT 0,
        window_start REAL NOT NULL DEFAULT 0,
        alerted INTEGER NOT NULL DEFAULT 0
    )""")
    return conn


DB: sqlite3.Connection


def _id_lock(rid: str) -> threading.Lock:
    # Serialize concurrent grabs of one release so a burst still costs one upstream fetch.
    with _id_locks_lock:
        return _id_locks.setdefault(rid, threading.Lock())


def _key_hash(query: dict) -> str:
    return hashlib.sha256((query.get("apikey", [""])[0]).encode()).hexdigest()


def _title_from(headers: dict) -> str:
    m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)', headers.get("content-disposition", ""))
    return m.group(1).removesuffix(".nzb") if m else ""


def _record_absorbed(rid: str, row: tuple, agent: str) -> None:
    """Count a repeat answered locally; alert once per day when it looks like a loop."""
    status, title, absorbed, window_start, alerted = row
    now = time.time()
    if now - window_start > 86400:
        absorbed, window_start, alerted = 0, now, 0
    absorbed += 1
    fire = absorbed >= LOOP_ALERT and not alerted
    with _db_lock:
        DB.execute("UPDATE releases SET absorbed=?, window_start=?, alerted=? WHERE rid=?",
                   (absorbed, window_start, 1 if fire else alerted, rid))
        DB.commit()
    if fire:
        name = title or f"Hydra release {rid}"
        msg = (f"{name} was requested {absorbed}x in 24h ({status}); answered locally, "
               f"indexer not contacted. Client: {agent or 'unknown'}. Something is in a grab loop.")
        log(f"LOOP {rid} {msg}")
        _notify("NZB grab loop detected", msg)


def _notify(title: str, msg: str) -> None:
    """Send through the shared lib/notifications.sh channels the watchdogs use."""
    if not (os.access(NOTIFY_LIB, os.R_OK) and os.access(NOTIFY_CONF, os.R_OK)):
        log(f"notify skipped: {NOTIFY_LIB} or {NOTIFY_CONF} not readable")
        return
    try:
        subprocess.run(["bash", "-c", '. "$1"; . "$2"; _notify "$3" "$4" warning',
                        "_", NOTIFY_CONF, NOTIFY_LIB, title, msg],
                       timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        log(f"notify failed: {e}")


def _forward(method: str, path: str, headers: dict, body: bytes | None):
    conn_cls = http.client.HTTPSConnection if UPSTREAM.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(UPSTREAM.hostname, UPSTREAM.port, timeout=TIMEOUT)
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, resp.getheaders(), data


def _fetch_redirect(url: str, agent: str):
    """GET an indexer download URL Hydra redirected to; errors come back as statuses, never raise."""
    req = Request(url, headers={"User-Agent": agent or "nzb-grab-guard/1.0"})
    try:
        with urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, resp.getheaders(), resp.read()
    except HTTPError as e:
        return e.code, [], e.read()
    except (URLError, OSError) as e:
        log(f"redirect fetch failed: {e}")
        return 599, [], b""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status: int, headers: list, body: bytes) -> None:
        self.send_response(status)
        for k, v in headers:
            if k.lower() not in _HOP_HEADERS and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _upstream_headers(self) -> dict:
        # Host is passed through untouched so Hydra keeps writing links that point back here.
        return {k: v for k, v in self.headers.items() if k.lower() not in _HOP_HEADERS}

    def _release_id(self) -> str | None:
        parts = urlsplit(self.path)
        m = _GETNZB_RE.search(parts.path)
        if m:
            return m.group(1)
        if parts.path.rstrip("/").endswith("/api"):
            q = parse_qs(parts.query)
            if q.get("t", [""])[0] == "get" and q.get("id"):
                return q["id"][0].split(".")[0]
        return None

    def _passthrough(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        try:
            status, headers, data = _forward(self.command, self.path, self._upstream_headers(), body)
        except OSError as e:
            self._send(502, [("Content-Type", "text/plain")], f"hydra unreachable: {e}".encode())
            return
        self._send(status, headers, data)

    def _grab(self, rid: str) -> None:
        query = parse_qs(urlsplit(self.path).query)
        key_hash = _key_hash(query)
        agent = self.headers.get("User-Agent", "")
        with _id_lock(rid):
            with _db_lock:
                row = DB.execute(
                    "SELECT status, expires, key_hash, headers, title, absorbed, window_start, alerted "
                    "FROM releases WHERE rid=?", (rid,)).fetchone()
            now = time.time()
            if row and row[1] > now and row[2] != key_hash:
                # Different apikey for a known release: let Hydra judge it, but never let
                # that answer overwrite (poison) the entry the real client relies on.
                self._passthrough()
                return
            if row and row[1] > now:
                status, _, _, hdrs, title, absorbed, window_start, alerted = row
                _record_absorbed(rid, (status, title, absorbed, window_start, alerted), agent)
                if status == "ok" and (NZB_DIR / f"{rid}.nzb").is_file():
                    headers = [tuple(h.split(": ", 1)) for h in hdrs.splitlines() if ": " in h]
                    self._send(200, headers, (NZB_DIR / f"{rid}.nzb").read_bytes())
                    return
                if status == "failed":
                    self._send(404, [("Content-Type", "text/plain")],
                               b"nzb-grab-guard: this release failed recently; not retrying the indexer")
                    return

            try:
                status, headers, data = _forward("GET", self.path, self._upstream_headers(), None)
            except OSError as e:
                # Hydra itself is down: transient, not the release's fault -- don't remember it.
                self._send(502, [("Content-Type", "text/plain")], f"hydra unreachable: {e}".encode())
                return

            hmap = {k.lower(): v for k, v in headers}
            if 300 <= status < 400 and hmap.get("location", "").startswith(("http://", "https://")):
                # Hydra serves some indexers in REDIRECT mode. Follow it here so the
                # NZB is still fetched once and cached instead of once per client retry.
                status, headers, data = _fetch_redirect(hmap["location"], self.headers.get("User-Agent", ""))
                hmap = {k.lower(): v for k, v in headers}

            if status == 200 and b"<nzb" in data[:4096]:
                kept = "\n".join(f"{k}: {v}" for k, v in headers if k.lower() in _KEEP_HEADERS
                                 or k.lower().startswith("x-dnzb"))
                title = _title_from(hmap)
                tmp = NZB_DIR / f"{rid}.nzb.tmp"
                tmp.write_bytes(data)
                tmp.replace(NZB_DIR / f"{rid}.nzb")
                self._store(rid, "ok", now + SUCCESS_TTL, key_hash, kept, status, title)
                log(f"GRAB ok {rid} {title or '?'} ({len(data)} B) cached")
                self._send(200, headers, data)
                return

            self._store(rid, "failed", now + FAILURE_TTL, key_hash, "", status, "")
            log(f"GRAB failed {rid} upstream={status}; blocking repeats for {FAILURE_TTL}s, returning 404")
            self._send(404, [("Content-Type", "text/plain")],
                       f"nzb-grab-guard: upstream returned {status}".encode())

    @staticmethod
    def _store(rid, status, expires, key_hash, headers, upstream_status, title) -> None:
        with _db_lock:
            DB.execute("""INSERT INTO releases (rid, status, expires, key_hash, headers, upstream_status, title,
                                                absorbed, window_start, alerted)
                          VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 0)
                          ON CONFLICT(rid) DO UPDATE SET status=excluded.status, expires=excluded.expires,
                              key_hash=excluded.key_hash, headers=excluded.headers,
                              upstream_status=excluded.upstream_status,
                              title=CASE WHEN excluded.title != '' THEN excluded.title ELSE releases.title END""",
                       (rid, status, expires, key_hash, headers, upstream_status, title, time.time()))
            DB.commit()

    def do_GET(self):
        rid = self._release_id()
        if rid:
            self._grab(rid)
        else:
            self._passthrough()

    do_POST = do_PUT = do_DELETE = _passthrough

    def do_HEAD(self):
        self._passthrough()

    def log_message(self, fmt, *args):
        pass


def _janitor() -> None:
    """Drop expired entries and their cached NZBs once an hour."""
    while True:
        time.sleep(3600)
        now = time.time()
        with _db_lock:
            expired = [r[0] for r in DB.execute(
                "SELECT rid FROM releases WHERE expires < ? AND window_start < ?", (now, now - 86400))]
            DB.executemany("DELETE FROM releases WHERE rid=?", [(r,) for r in expired])
            DB.commit()
        for rid in expired:
            (NZB_DIR / f"{rid}.nzb").unlink(missing_ok=True)
        if expired:
            log(f"janitor: dropped {len(expired)} expired entries")


def main():
    global DB
    NZB_DIR.mkdir(parents=True, exist_ok=True)
    DB = _db()
    threading.Thread(target=_janitor, daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    log(f"nzb-grab-guard listening on {HOST}:{PORT} -> {UPSTREAM.geturl()} "
        f"(success_ttl={SUCCESS_TTL}s failure_ttl={FAILURE_TTL}s loop_alert={LOOP_ALERT})")
    server.serve_forever()


if __name__ == "__main__":
    main()
