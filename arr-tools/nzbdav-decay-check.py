#!/usr/bin/env python3
"""
Flag library files whose usenet article availability has decayed.

nzbdav verifies that a release's articles exist at grab time
(`api.ensure-article-existence-categories`), but `repair.enable=false` means
nothing ever re-checks. Providers drop releases over time (DMCA/retention), so a
file that imported healthy can silently degrade to a single provider — or to
none. A high-bitrate 2160p remux served by one slow provider cannot sustain
playback, which shows up as "loads slowly, then buffers forever" in Emby.

This samples segments spread across each file and STATs them on every enabled
provider, then reports anything down to 0 or 1 provider.

  DEAD    nothing found anywhere unplayable, re-grab required
  HOLES   partial everywhere     gaps mid-file; re-grab or par2 repair
  RISK    1 provider             no failover; will stutter if that provider is slow
  THIN    2 providers            degraded, worth watching
  OK      3+ providers

Usage:
  ./nzbdav-decay-check.py                          # default categories, files >= 20 GiB
  ./nzbdav-decay-check.py --category radarr-4k --min-size 40
  ./nzbdav-decay-check.py --all-categories --min-size 30 --json /tmp/decay.json
  ./nzbdav-decay-check.py --recheck-days 0         # ignore the result cache

Exit codes: 0 = nothing flagged, 1 = DEAD/HOLES/RISK found, 2 = error.
"""

import argparse
import json
import os
import re
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time

# Site layout from the shared media-tools JSON (see configs/media-tools.json.example):
#   "nzbdav": {"config_dir": ..., "categories": [...], "default_categories": [...]}
_CFG_PATH = os.environ.get("MEDIA_TOOLS_CONFIG", "/opt/swizzin-extras/media-tools.json")
try:
    with open(_CFG_PATH) as _fh:
        _NZBDAV_CFG = json.load(_fh).get("nzbdav", {})
except FileNotFoundError:
    _NZBDAV_CFG = {}

NZBDAV_CONFIG = _NZBDAV_CFG.get("config_dir", "/opt/nzbdav/config")
DB = os.path.join(NZBDAV_CONFIG, "db.sqlite")
BLOBS = os.path.join(NZBDAV_CONFIG, "blobs")
CACHE_DB = "/var/lib/nzbdav-decay-check.sqlite"

# Message-ids: local part has no '@'; both halves are printable ASCII.
MSGID_RE = re.compile(rb"[!-?A-~]{8,80}@[!-?A-~]{3,60}")

# Fractions through the file to sample, so we catch partial decay (a release can
# lose its tail while the header still STATs fine).
SAMPLE_POINTS = (0.02, 0.15, 0.30, 0.45, 0.60, 0.75, 0.90, 0.98)

# nzbdav keeps each category's imports under /content/<category>/
_CATEGORIES = _NZBDAV_CFG.get("categories", ["radarr", "sonarr"])
CATEGORY_PATHS = {c: f"/content/{c}/" for c in _CATEGORIES}
DEFAULT_CATEGORIES = tuple(_NZBDAV_CFG.get("default_categories", _CATEGORIES))

GIB = 1024 ** 3


# ---------------------------------------------------------------- providers


def load_providers():
    """Read enabled providers out of nzbdav's own config (Type 0 = disabled)."""
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        row = con.execute(
            "SELECT ConfigValue FROM ConfigItems WHERE ConfigName='usenet.providers'"
        ).fetchone()
    finally:
        con.close()
    if not row:
        raise SystemExit("no usenet.providers in nzbdav config")

    out = []
    for p in json.loads(row[0]).get("Providers", []):
        if p.get("Type", 0) == 0:
            continue
        out.append(
            {
                "name": p["Host"].split(".")[1] if p["Host"].count(".") >= 2 else p["Host"],
                "host": p["Host"],
                "port": int(p.get("Port", 563)),
                "ssl": bool(p.get("UseSsl", True)),
                "user": p.get("User") or "",
                "pw": p.get("Pass") or "",
            }
        )
    if not out:
        raise SystemExit("no enabled usenet providers")
    return out


class Provider:
    """One persistent NNTP connection, reconnecting on drop."""

    def __init__(self, cfg, timeout=30):
        self.cfg = cfg
        self.name = cfg["name"]
        self.timeout = timeout
        self.sock = None
        self.fp = None
        self.errors = 0

    def connect(self):
        self.close()
        sock = socket.create_connection((self.cfg["host"], self.cfg["port"]), timeout=self.timeout)
        if self.cfg["ssl"]:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(sock, server_hostname=self.cfg["host"])
        sock.settimeout(self.timeout)
        self.sock, self.fp = sock, sock.makefile("rb")
        self.fp.readline()  # greeting
        if self.cfg["user"]:
            self._cmd("AUTHINFO USER " + self.cfg["user"])
            resp = self._cmd("AUTHINFO PASS " + self.cfg["pw"])
            if not resp.startswith("281"):
                raise RuntimeError(f"{self.name}: auth failed: {resp[:60]}")

    def _cmd(self, line):
        self.sock.sendall((line + "\r\n").encode())
        return self.fp.readline().decode("latin-1", "replace").strip()

    def stat(self, msgid):
        """True if the article exists, False if 430, None if the check failed."""
        for attempt in (0, 1):
            try:
                if self.sock is None:
                    self.connect()
                resp = self._cmd(f"STAT <{msgid}>")
                if resp.startswith("223"):
                    return True
                if resp.startswith("430") or resp.startswith("423"):
                    return False
                if not resp:  # dropped
                    raise RuntimeError("empty response")
                return None
            except Exception:
                self.close()
                if attempt:
                    self.errors += 1
                    return None
                time.sleep(1.0)
        return None

    def close(self):
        for h in (self.fp, self.sock):
            try:
                if h:
                    h.close()
            except Exception:
                pass
        self.sock = self.fp = None


# ---------------------------------------------------------------- candidates


def pick_candidates(categories, min_size, limit, all_categories, path_like=None):
    where = ["FileSize IS NOT NULL", "FileSize >= ?"]
    params = [int(min_size * GIB)]
    if not all_categories:
        paths = [CATEGORY_PATHS[c] for c in categories]
        where.append("(" + " OR ".join("Path LIKE ?" for _ in paths) + ")")
        params += [p + "%" for p in paths]
    if path_like:
        where.append("Path LIKE ?")
        params.append(f"%{path_like}%")

    sql = (
        "SELECT Id, Name, Path, FileSize, FileBlobId, GeneratedSymlinkPath "
        "FROM DavItems WHERE " + " AND ".join(where) + " ORDER BY FileSize DESC"
    )
    if limit:
        sql += f" LIMIT {int(limit)}"

    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        return con.execute(sql, params).fetchall()
    finally:
        con.close()


def blob_path(blob_id):
    b = (blob_id or "").lower()
    if len(b) < 4:
        return None
    return os.path.join(BLOBS, b[:2], b[2:4], b)


def segment_ids(blob_id):
    """Message-ids in file order. Blobs are zstd; no python module, so shell out."""
    path = blob_path(blob_id)
    if not path or not os.path.exists(path):
        return []
    try:
        raw = subprocess.run(
            ["zstd", "-dc", path], capture_output=True, timeout=120
        ).stdout
    except Exception:
        return []
    seen, out = set(), []
    for m in MSGID_RE.findall(raw):
        s = m.decode("ascii", "ignore")
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out


def sample(ids, per_point):
    n = len(ids)
    if not n:
        return []
    picked, seen = [], set()
    for frac in SAMPLE_POINTS:
        base = min(int(n * frac), n - 1)
        for off in range(per_point):
            i = min(base + off, n - 1)
            if i not in seen:
                seen.add(i)
                picked.append(ids[i])
    return picked


# ---------------------------------------------------------------- cache


def open_cache():
    con = sqlite3.connect(CACHE_DB)
    con.execute(
        "CREATE TABLE IF NOT EXISTS checks ("
        " dav_id TEXT PRIMARY KEY, checked_at INTEGER, sampled INTEGER,"
        " present_json TEXT, verdict TEXT)"
    )
    con.commit()
    return con


def cached(con, dav_id, max_age_days):
    if max_age_days <= 0:
        return None
    row = con.execute(
        "SELECT checked_at, sampled, present_json, verdict FROM checks WHERE dav_id=?",
        (dav_id,),
    ).fetchone()
    if not row:
        return None
    if time.time() - row[0] > max_age_days * 86400:
        return None
    return {"sampled": row[1], "present": json.loads(row[2]), "verdict": row[3]}


def store(con, dav_id, sampled, present, verdict):
    con.execute(
        "INSERT INTO checks (dav_id, checked_at, sampled, present_json, verdict)"
        " VALUES (?,?,?,?,?) ON CONFLICT(dav_id) DO UPDATE SET"
        " checked_at=excluded.checked_at, sampled=excluded.sampled,"
        " present_json=excluded.present_json, verdict=excluded.verdict",
        (dav_id, int(time.time()), sampled, json.dumps(present), verdict),
    )
    con.commit()


# ---------------------------------------------------------------- checking


def verdict_for(present, sampled):
    """Classify by how many providers hold the *whole* sample, then by partials.

    A provider only counts as a real source if it has every sampled segment — a
    stream falls over on the gap otherwise. But "no complete provider" is not the
    same as "gone": a release sitting at 7/8 everywhere still has most of its
    articles and may only need a par2 repair, so it is reported as HOLES rather
    than DEAD. DEAD is reserved for nothing found anywhere.
    """
    full = [n for n, hits in present.items() if sampled and hits == sampled]
    best = max(present.values()) if present else 0
    if not full:
        if best == 0:
            return "DEAD", full          # no provider has any sampled segment
        return "HOLES", full             # partial everywhere: gaps mid-file
    if len(full) == 1:
        return "RISK", full
    if len(full) == 2:
        return "THIN", full
    return "OK", full


def check_file(providers, ids_sample):
    """STAT the sample on every provider in parallel (one connection each)."""
    present = {p.name: 0 for p in providers}
    lock = threading.Lock()

    def worker(prov):
        hits = 0
        for mid in ids_sample:
            if prov.stat(mid):
                hits += 1
        with lock:
            present[prov.name] = hits

    threads = [threading.Thread(target=worker, args=(p,)) for p in providers]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return present


def title_of(row):
    _id, name, path, _size, _blob, symlink = row
    if symlink:
        return os.path.basename(os.path.dirname(symlink)) or os.path.basename(symlink)
    # nzbdav stores obfuscated filenames; the release dir is the useful label
    parent = os.path.basename(os.path.dirname(path))
    return parent or name


def main():
    try:  # findings should appear live even when redirected to a log
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="Flag decayed usenet availability in the nzbdav library.")
    ap.add_argument("--category", default=",".join(DEFAULT_CATEGORIES),
                    help="comma-separated: " + ", ".join(CATEGORY_PATHS))
    ap.add_argument("--all-categories", action="store_true")
    ap.add_argument("--min-size", type=float, default=20.0, help="GiB (default 20)")
    ap.add_argument("--samples", type=int, default=1, help="segments per sample point (default 1, x8 points)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--path-like", help="only files whose nzbdav path contains this substring")
    ap.add_argument("--recheck-days", type=int, default=14, help="0 disables the cache")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    cats = [c.strip() for c in args.category.split(",") if c.strip()]
    for c in cats:
        if c not in CATEGORY_PATHS:
            raise SystemExit(f"unknown category {c!r}; known: {', '.join(CATEGORY_PATHS)}")

    rows = pick_candidates(cats, args.min_size, args.limit, args.all_categories, args.path_like)
    if not rows:
        print("no files matched")
        return 0

    providers = [Provider(c) for c in load_providers()]
    cache = open_cache()

    scope = "all categories" if args.all_categories else ",".join(cats)
    if not args.quiet:
        print(f"checking {len(rows)} files >= {args.min_size:g} GiB [{scope}] "
              f"against {len(providers)} providers "
              f"({len(SAMPLE_POINTS) * args.samples} segments each)\n")

    results, flagged = [], 0
    t0 = time.time()
    try:
        for n, row in enumerate(rows, 1):
            dav_id, name, path, size, blob_id, _sym = row
            label = title_of(row)

            hit = cached(cache, dav_id, args.recheck_days)
            if hit:
                present, sampled, verdict = hit["present"], hit["sampled"], hit["verdict"]
                full = [k for k, v in present.items() if sampled and v == sampled]
                cached_note = " (cached)"
            else:
                ids = segment_ids(blob_id)
                if not ids:
                    verdict, present, sampled, full = "NOSEGS", {}, 0, []
                else:
                    sel = sample(ids, args.samples)
                    present = check_file(providers, sel)
                    sampled = len(sel)
                    verdict, full = verdict_for(present, sampled)
                store(cache, dav_id, sampled, present, verdict)
                cached_note = ""

            rec = {
                "verdict": verdict, "title": label, "size_gib": round(size / GIB, 1),
                "providers_full": full, "present": present, "sampled": sampled,
                "path": path, "dav_id": dav_id,
            }
            results.append(rec)

            if verdict in ("DEAD", "HOLES", "RISK"):
                flagged += 1
            if not args.quiet and (verdict in ("DEAD", "RISK", "THIN", "NOSEGS")):
                detail = ", ".join(f"{k}:{v}/{sampled}" for k, v in sorted(present.items()))
                print(f"  [{verdict:6}] {rec['size_gib']:6.1f} GiB  {label[:58]:58} {detail}")
            if not args.quiet and n % 100 == 0:
                print(f"    ... {n}/{len(rows)} ({time.time()-t0:.0f}s)", file=sys.stderr)
    except KeyboardInterrupt:
        print("\ninterrupted; partial results below", file=sys.stderr)
    finally:
        for p in providers:
            p.close()
        cache.close()

    counts = {}
    for r in results:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1

    print(f"\nchecked {len(results)} files in {time.time()-t0:.0f}s")
    for v in ("DEAD", "HOLES", "RISK", "THIN", "OK", "NOSEGS"):
        if counts.get(v):
            print(f"  {v:6} {counts[v]}")

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(results, fh, indent=1)
        print(f"\nwrote {args.json_out}")

    if flagged:
        print(f"\n{flagged} file(s) need attention (DEAD/HOLES/RISK).")
        print("Pre-flight the replacement before grabbing — prefer the freshest posting.")
    return 1 if flagged else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)
