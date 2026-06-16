#!/usr/bin/env python3
"""
Arr Maintenance — dedup, queue cleanup, database health.

Runs post-sync to fix issues caused by multiple import lists adding
same-title-different-TMDB movies, and clears stale Sonarr queue items.

Usage:
    arr-maintenance.py                  # Full maintenance (dedup + queue + db)
    arr-maintenance.py --dedup          # Only remove duplicate movies
    arr-maintenance.py --queue          # Only clean Sonarr queues
    arr-maintenance.py --dry-run        # Preview changes without applying
    arr-maintenance.py --debug          # Verbose output

Designed to run after mdblist-sync.py via systemd timer.
"""

import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# =============================================================================
# Configuration
# =============================================================================

DRY_RUN = "--dry-run" in sys.argv
DEBUG = "--debug" in sys.argv
DEDUP_ONLY = "--dedup" in sys.argv
QUEUE_ONLY = "--queue" in sys.argv
ALL_MODE = not DEDUP_ONLY and not QUEUE_ONLY

LOG_FILE = "/var/log/arr-maintenance.log"


# =============================================================================
# Logging
# =============================================================================

class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[0;33m"
    BOLD = "\033[1m"
    NC = "\033[0m"


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            # Strip ANSI codes for log file
            clean = re.sub(r"\033\[[0-9;]*m", "", line)
            f.write(clean + "\n")
    except OSError:
        pass


def log_debug(msg: str):
    if DEBUG:
        log(f"  [debug] {msg}")


def log_warn(msg: str):
    log(f"{Colors.YELLOW}WARN:{Colors.NC} {msg}")


def log_error(msg: str):
    log(f"{Colors.RED}ERROR:{Colors.NC} {msg}")


def log_success(msg: str):
    log(f"{Colors.GREEN}OK:{Colors.NC} {msg}")


# =============================================================================
# Arr API client
# =============================================================================

class ArrAPI:
    def __init__(self, base_url: str, api_key: str, timeout: int = 120):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def _request(self, method: str, path: str, data: dict = None) -> any:
        sep = "&" if "?" in path else "?"
        url = f"{self.base_url}/api/v3{path}{sep}apikey={self.api_key}"
        body = json.dumps(data).encode() if data else None
        headers = {"Content-Type": "application/json"} if data else {}
        req = Request(url, data=body, headers=headers, method=method)
        resp = urlopen(req, timeout=self.timeout)
        if resp.status == 200:
            return json.loads(resp.read())
        return None

    def get(self, path: str) -> any:
        return self._request("GET", path)

    def delete(self, path: str) -> bool:
        try:
            sep = "&" if "?" in path else "?"
            url = f"{self.base_url}/api/v3{path}{sep}apikey={self.api_key}"
            req = Request(url, method="DELETE")
            urlopen(req, timeout=self.timeout)
            return True
        except Exception as e:
            log_error(f"DELETE {path} failed: {e}")
            return False

    def delete_bulk(self, path: str, data: dict) -> bool:
        try:
            sep = "&" if "?" in path else "?"
            url = f"{self.base_url}/api/v3{path}{sep}apikey={self.api_key}"
            req = Request(
                url,
                data=json.dumps(data).encode(),
                headers={"Content-Type": "application/json"},
                method="DELETE",
            )
            urlopen(req, timeout=self.timeout)
            return True
        except Exception as e:
            log_error(f"DELETE BULK {path} failed: {e}")
            return False


# =============================================================================
# Instance discovery
# =============================================================================

def get_master_user() -> str:
    """Get the swizzin master username."""
    try:
        with open("/root/.master.info") as f:
            return f.read().strip().split(":")[0]
    except FileNotFoundError:
        # Fallback: first user in /home
        for d in sorted(Path("/home").iterdir()):
            if d.is_dir() and not d.name.startswith("."):
                return d.name
    return ""


def discover_arr_instance(config_path: str) -> Optional[Tuple[str, str, str]]:
    """Parse config.xml to get (port, api_key, url_base)."""
    try:
        tree = ET.parse(config_path)
        root = tree.getroot()
        port = root.findtext("Port", "")
        api_key = root.findtext("ApiKey", "")
        url_base = root.findtext("UrlBase", "")
        if port and api_key:
            return port, api_key, url_base or ""
    except Exception:
        pass
    return None


def discover_all_instances() -> Tuple[List[Tuple[str, ArrAPI]], List[Tuple[str, ArrAPI]]]:
    """Find all running Radarr and Sonarr instances."""
    user = get_master_user()
    radarr_instances = []
    sonarr_instances = []

    config_dir = Path(f"/home/{user}/.config")
    if not config_dir.exists():
        return [], []

    for d in sorted(config_dir.iterdir()):
        if not d.is_dir():
            continue
        name = d.name.lower()

        config_xml = d / "config.xml"
        if not config_xml.exists():
            continue

        result = discover_arr_instance(str(config_xml))
        if not result:
            continue

        port, api_key, url_base = result
        base_url = f"http://127.0.0.1:{port}"
        if url_base:
            base_url += f"/{url_base}"

        api = ArrAPI(base_url, api_key)

        if "radarr" in name:
            radarr_instances.append((d.name, api))
            log_debug(f"Found Radarr instance: {d.name} on port {port}")
        elif "sonarr" in name:
            sonarr_instances.append((d.name, api))
            log_debug(f"Found Sonarr instance: {d.name} on port {port}")

    return radarr_instances, sonarr_instances


# =============================================================================
# Radarr Dedup
# =============================================================================

def find_radarr_duplicates(api: ArrAPI) -> Dict[str, List[dict]]:
    """
    Find duplicate movies:
    1. Exact: same title + year, different TMDB IDs
    2. Near-year: same title, year ±1, where one is clearly inferior
    """
    movies = api.get("/movie")
    if not movies:
        return {}

    # Exact title+year duplicates
    by_key = defaultdict(list)
    for m in movies:
        title = (m.get("title") or "").lower().rstrip(".")
        year = m.get("year", 0)
        by_key[(title, year)].append(m)

    dupes = {}
    for k, v in by_key.items():
        if len(v) > 1:
            dupes[f"{k[0]}|{k[1]}"] = v

    # Near-year duplicates (same title, year ±1)
    by_title = defaultdict(list)
    for m in movies:
        by_title[(m.get("title") or "").lower().rstrip(".")].append(m)

    for title, entries in by_title.items():
        if len(entries) < 2:
            continue
        # Check each pair for year ±1
        for i, a in enumerate(entries):
            for b in entries[i + 1:]:
                ya, yb = a.get("year", 0), b.get("year", 0)
                if abs(ya - yb) > 1 or ya == yb:
                    continue
                key = f"{title}|{ya}-{yb}"
                if key not in dupes:
                    # Only flag if one is clearly inferior (< 500 votes AND < 10% of other)
                    va = (a.get("ratings", {}).get("imdb", {}).get("votes", 0) or 0)
                    vb = (b.get("ratings", {}).get("imdb", {}).get("votes", 0) or 0)
                    max_v = max(va, vb)
                    min_v = min(va, vb)
                    if min_v < 500 and max_v > 0 and min_v < max_v * 0.1:
                        dupes[key] = [a, b]

    return dupes


def pick_best_movie(entries: List[dict]) -> dict:
    """
    Pick the best movie from a set of same-title duplicates.

    Priority:
    1. Has file on disk (real content)
    2. Higher IMDB vote count (more well-known)
    3. Higher IMDB rating
    4. Lower TMDB ID (usually the canonical entry)
    """
    def score(m):
        has_file = 1_000_000 if m.get("hasFile") else 0
        imdb_votes = (m.get("ratings", {}).get("imdb", {}).get("votes", 0) or 0)
        imdb_rating = (m.get("ratings", {}).get("imdb", {}).get("value", 0) or 0) * 100
        return has_file + imdb_votes + imdb_rating

    return max(entries, key=score)


def dedup_radarr(name: str, api: ArrAPI) -> int:
    """Find and remove duplicate movies from a Radarr instance."""
    log(f"\n{Colors.BOLD}Deduplicating {name}...{Colors.NC}")

    dupes = find_radarr_duplicates(api)
    if not dupes:
        log(f"  No duplicates found in {name}")
        return 0

    log(f"  Found {len(dupes)} duplicate groups")
    removed = 0

    for (title, year), entries in sorted(dupes.items()):
        best = pick_best_movie(entries)
        to_remove = [e for e in entries if e["id"] != best["id"]]

        for m in to_remove:
            has_file = m.get("hasFile", False)
            size_gb = (m.get("sizeOnDisk", 0) or 0) / 1024**3
            imdb = m.get("imdbId", "?")
            tmdb = m.get("tmdbId", "?")
            m_votes = m.get("ratings", {}).get("imdb", {}).get("votes", 0) or 0
            best_votes = best.get("ratings", {}).get("imdb", {}).get("votes", 0) or 0

            # Skip entries with files — always needs manual review
            if has_file:
                log_warn(
                    f"  {title.title()} ({year}): SKIP removal of tmdb={tmdb} "
                    f"(has file, {size_gb:.1f}GB) — manual review needed"
                )
                continue

            # Flag when removing a much more popular entry (likely wrong choice)
            if m_votes > best_votes * 10 and m_votes > 1000:
                log_warn(
                    f"  {title.title()} ({year}): SKIP removal of tmdb={tmdb} "
                    f"({m_votes} IMDB votes vs {best_votes}) — kept entry may be wrong movie"
                )
                continue

            action = "WOULD REMOVE" if DRY_RUN else "Removing"
            log(f"  {action}: {title.title()} ({year}) tmdb={tmdb} imdb={imdb}")
            log_debug(f"    Keeping: tmdb={best['tmdbId']} imdb={best.get('imdbId','?')}")

            if not DRY_RUN:
                if api.delete(f"/movie/{m['id']}?deleteFiles=false&addImportExclusion=true"):
                    removed += 1
                else:
                    log_error(f"  Failed to remove movie id={m['id']}")

    if removed:
        log_success(f"  {name}: removed {removed} duplicate movies")
    return removed


# =============================================================================
# Sonarr Queue Cleanup
# =============================================================================

def clean_sonarr_queue(name: str, api: ArrAPI) -> int:
    """Remove importBlocked and missing-path items from Sonarr queue."""
    log(f"\n{Colors.BOLD}Cleaning queue for {name}...{Colors.NC}")

    total_removed = 0
    max_rounds = 5
    consecutive_failures = 0

    for round_num in range(1, max_rounds + 1):
        try:
            data = api.get("/queue?pageSize=200&page=1&includeUnknownSeriesItems=true")
        except Exception as e:
            log_error(f"  Failed to fetch queue: {e}")
            break

        if not data:
            break

        total = data.get("totalRecords", 0)
        records = data.get("records", [])
        if not records:
            break

        blocked_ids = []
        missing_ids = []

        for r in records:
            rid = r["id"]
            state = r.get("trackedDownloadState", "")

            if state == "importBlocked":
                blocked_ids.append(rid)
                continue

            # Check for missing output paths
            path = r.get("outputPath", "")
            if path:
                try:
                    os.lstat(path)
                except (FileNotFoundError, OSError):
                    missing_ids.append(rid)

        remove_ids = blocked_ids + missing_ids
        if not remove_ids:
            log(f"  No blocked/missing items in {name} (queue: {total})")
            break

        action = "WOULD REMOVE" if DRY_RUN else "Removing"
        log(f"  Round {round_num}: {action} {len(blocked_ids)} blocked + "
            f"{len(missing_ids)} missing-path items (queue: {total})")

        if DRY_RUN:
            total_removed += len(remove_ids)
            break

        # Try bulk delete; on persistent 500s, skip this instance
        if api.delete_bulk(
            "/queue/bulk?removeFromClient=false&blocklist=false&skipRedownload=true",
            {"ids": remove_ids},
        ):
            total_removed += len(remove_ids)
            consecutive_failures = 0
        else:
            consecutive_failures += 1
            if consecutive_failures >= 2:
                log_warn(f"  {name}: persistent API errors, skipping remaining cleanup")
                break

        time.sleep(1)

    if total_removed:
        log_success(f"  {name}: removed {total_removed} stale queue items")
    return total_removed




# =============================================================================
# Main
# =============================================================================

def main():
    mode = "DRY RUN" if DRY_RUN else "LIVE"
    log(f"\n{'='*60}")
    log(f"Arr Maintenance [{mode}]")
    log(f"{'='*60}")

    radarr_apis, sonarr_apis = discover_all_instances()

    if not radarr_apis and not sonarr_apis:
        log_error("No Radarr or Sonarr instances found")
        sys.exit(1)

    log(f"Found: {len(radarr_apis)} Radarr, {len(sonarr_apis)} Sonarr instances")

    total_dedup = 0
    total_queue = 0

    # Radarr dedup
    if ALL_MODE or DEDUP_ONLY:
        for name, api in radarr_apis:
            total_dedup += dedup_radarr(name, api)

    # Sonarr queue cleanup
    if ALL_MODE or QUEUE_ONLY:
        for name, api in sonarr_apis:
            total_queue += clean_sonarr_queue(name, api)

    # Summary
    log(f"\n{'='*60}")
    log(f"Summary: {total_dedup} duplicates removed, {total_queue} queue items cleaned")
    log(f"{'='*60}\n")


if __name__ == "__main__":
    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        sys.exit(0)
    main()
