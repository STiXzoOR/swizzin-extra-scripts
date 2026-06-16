#!/usr/bin/env python3
"""
Local HTTP proxy for mdblist.com list JSON endpoints.

mdblist.com returns items with `tvdbid: null` (shows) or `tmdbid: null`
(movies) when the list curator hasn't matched the title to TheTVDB/TMDB
yet. Sonarr's CustomImport JSON parser is strict and fails the entire
list when it encounters a null int, surfacing as:

    Error converting value {null} to type 'System.Int32'

This proxy fetches upstream, drops items with the wrong-typed null id
for their mediatype, and re-emits valid JSON. Sonarr/Radarr are pointed
at the proxy URL instead of mdblist.com.

Usage:
    GET /lists/<user>/<slug>/json   ->  proxies to https://mdblist.com/lists/<user>/<slug>/json

Env:
    MDBLIST_PROXY_HOST  bind host, default 127.0.0.1
    MDBLIST_PROXY_PORT  bind port, default 11550
    MDBLIST_PROXY_TTL   cache TTL seconds, default 300
"""

import json
import os
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

UPSTREAM = "https://mdblist.com"
HOST = os.environ.get("MDBLIST_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("MDBLIST_PROXY_PORT", "11550"))
TTL = int(os.environ.get("MDBLIST_PROXY_TTL", "300"))
TIMEOUT = 15

_cache: dict[str, tuple[float, bytes]] = {}
_lock = threading.Lock()


_NULLABLE_INT_KEYS = ("tvdbid", "tmdbid", "tvmazeid")


def _filter(data):
    """Normalize mdblist items so Sonarr/Radarr CustomImport JSON parsers don't crash.

    mdblist returns items with ``tvdbid: null`` (shows) or ``tmdbid: null`` (movies)
    when the curator hasn't matched the title to TheTVDB/TMDB. Sonarr's
    CustomImport deserializes those as ``System.Int32`` and crashes the whole
    list when it sees a null. Radarr's lists hit the same shape.

    Strategy: drop the null-int *fields* (so the JSON parser uses the default
    int rather than choking on null), and only drop the *item* if none of the
    surviving id fields can identify it (no tvdbid/tmdbid/imdb_id at all).
    """
    if not isinstance(data, list):
        return data, 0, 0
    kept = []
    nulled = 0
    dropped = 0
    for item in data:
        if not isinstance(item, dict):
            kept.append(item)
            continue
        for key in _NULLABLE_INT_KEYS:
            if key in item and item[key] is None:
                del item[key]
                nulled += 1
        has_id = any(item.get(k) for k in (*_NULLABLE_INT_KEYS, "imdb_id"))
        if not has_id:
            dropped += 1
            continue
        kept.append(item)
    return kept, nulled, dropped


def _fetch(path: str) -> tuple[int, bytes, str]:
    """Fetch upstream and return (status, body, content_type). Honors short cache."""
    now = time.time()
    with _lock:
        cached = _cache.get(path)
        if cached and cached[0] > now:
            return 200, cached[1], "application/json"

    url = f"{UPSTREAM}{path}"
    req = Request(url, headers={"User-Agent": "mdblist-filter-proxy/1.0"})
    try:
        with urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read()
            ctype = resp.headers.get("Content-Type", "application/json")
    except HTTPError as e:
        return e.code, str(e).encode(), "text/plain"
    except URLError as e:
        return 502, f"upstream error: {e}".encode(), "text/plain"

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return 200, raw, ctype

    filtered, nulled, dropped = _filter(data)
    body = json.dumps(filtered).encode()
    if nulled or dropped:
        sys.stderr.write(
            f"[{time.strftime('%F %T')}] {path}: stripped {nulled} null id fields, "
            f"dropped {dropped} items (no usable id)\n"
        )
    with _lock:
        _cache[path] = (now + TTL, body)
    return 200, body, "application/json"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith("/lists/") or not self.path.endswith("/json"):
            self.send_error(404, "only /lists/<user>/<slug>/json is proxied")
            return
        status, body, ctype = _fetch(self.path)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{time.strftime('%F %T')}] {self.address_string()} {fmt % args}\n")


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"mdblist-filter-proxy listening on {HOST}:{PORT} (ttl={TTL}s)\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
