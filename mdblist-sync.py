#!/usr/bin/env python3
"""
MDBList Auto-Sync for Sonarr & Radarr

Automatically discovers popular lists from MDBList.com and adds them as
import lists in Sonarr/Radarr, so they handle polling and downloading.

Usage:
    mdblist-sync.py                    # Sync: discover lists, add to *arr
    mdblist-sync.py --cleanup          # Remove stale/low-quality managed lists
    mdblist-sync.py --status           # Show current managed lists
    mdblist-sync.py --dry-run          # Preview changes without applying
    mdblist-sync.py --debug            # Verbose output

Requires: MDBList API key (free from https://mdblist.com/preferences/)
"""

import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from urllib.parse import urlencode

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = os.environ.get(
    "MDBLIST_SYNC_CONFIG",
    "/opt/swizzin-extras/mdblist-sync.conf",
)
STATE_PATH = os.environ.get(
    "MDBLIST_SYNC_STATE",
    "/opt/swizzin-extras/mdblist-sync.state.json",
)

MDBLIST_API_BASE = "https://api.mdblist.com"
MDBLIST_LIST_BASE = "https://mdblist.com/lists"

# Default config values (overridden by config file)
DEFAULTS = {
    # MDBList API key - REQUIRED
    "MDBLIST_API_KEY": "",
    # Discovery: minimum likes for a list to be considered
    "MIN_LIKES": "20",
    # Discovery: minimum items in a list
    "MIN_ITEMS": "5",
    # Discovery: minimum likes for anime lists (lower bar, default: MIN_LIKES / 4)
    "MIN_LIKES_ANIME": "5",
    # Maximum number of lists to manage per app type (movie/show)
    "MAX_LISTS_MOVIES": "20",
    "MAX_LISTS_SHOWS": "20",
    # Search terms for discovering lists (comma-separated)
    # Covers streaming platforms, genres, and popular categories
    "SEARCH_TERMS": "netflix,disney,hbo,amazon prime,hulu,apple tv,paramount,peacock,crunchyroll,trending,top rated,imdb,anime,sci-fi,horror,thriller,documentary,romance,comedy,action,crime,new releases,best 2026,oscar,mystery,fantasy",
    # Specific list IDs to always include (comma-separated MDBList list IDs)
    "PINNED_LISTS": "",
    # Specific list IDs to never include (comma-separated MDBList list IDs)
    "BLOCKED_LISTS": "",
    # Radarr settings
    "RADARR_MONITOR": "movieOnly",
    "RADARR_MIN_AVAILABILITY": "released",
    "RADARR_SEARCH_ON_ADD": "true",
    "RADARR_QUALITY_PROFILE": "",  # Auto-detect first profile if empty
    "RADARR_ROOT_FOLDER": "",  # Auto-detect first folder if empty
    # Sonarr settings
    "SONARR_MONITOR": "all",
    "SONARR_SERIES_TYPE": "standard",
    "SONARR_SEASON_FOLDER": "true",
    "SONARR_SEARCH_ON_ADD": "true",
    "SONARR_QUALITY_PROFILE": "",
    "SONARR_ROOT_FOLDER": "",
    # Override instance detection (comma-separated)
    # Format: "radarr,radarr-4k" or "sonarr,sonarr-anime"
    "RADARR_INSTANCES": "",
    "SONARR_INSTANCES": "",
    # Cleanup: remove managed lists with fewer likes than this
    "CLEANUP_MIN_LIKES": "20",
    # Tag prefix for managed import lists (to identify our lists)
    "LIST_NAME_PREFIX": "[mdblist-auto]",
}

# *arr instance config paths
ARR_INSTANCES = {
    "radarr": {
        "type": "radarr",
        "config_paths": ["/home/{user}/.config/Radarr/config.xml"],
    },
    "radarr-4k": {
        "type": "radarr",
        "config_paths": [
            "/home/{user}/.config/radarr-4k/config.xml",
            "/home/{user}/.config/radarr4k/config.xml",
            "/home/{user}/.config/Radarr4k/config.xml",
        ],
    },
    "sonarr": {
        "type": "sonarr",
        "config_paths": ["/home/{user}/.config/Sonarr/config.xml"],
    },
    "sonarr-4k": {
        "type": "sonarr",
        "config_paths": [
            "/home/{user}/.config/sonarr-4k/config.xml",
            "/home/{user}/.config/sonarr4k/config.xml",
            "/home/{user}/.config/Sonarr4k/config.xml",
        ],
    },
    "sonarr-anime": {
        "type": "sonarr",
        "config_paths": ["/home/{user}/.config/sonarr-anime/config.xml"],
    },
}

# Keywords that indicate an anime list (matched case-insensitively in name/description)
ANIME_KEYWORDS = ["anime", "crunchyroll", "funimation", "anilist", "myanimelist", "mal top"]


def is_anime_list(lst: dict) -> bool:
    """Check if a list is anime-related based on its name and description."""
    text = f"{lst.get('name', '')} {lst.get('description', '')}".lower()
    return any(kw in text for kw in ANIME_KEYWORDS)


# =============================================================================
# Logging
# =============================================================================

class Colors:
    CYAN = '\033[0;36m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[0;33m'
    RED = '\033[0;31m'
    BLUE = '\033[0;34m'
    MAGENTA = '\033[0;35m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    NC = '\033[0m'


_debug_mode = False


def log(msg: str):
    print(f"{Colors.CYAN}[INFO]{Colors.NC} {msg}")


def log_success(msg: str):
    print(f"{Colors.GREEN}[OK]{Colors.NC} {msg}")


def log_warn(msg: str):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")


def log_error(msg: str):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}", file=sys.stderr)


def log_dry(msg: str):
    print(f"{Colors.YELLOW}[DRY-RUN]{Colors.NC} {msg}")


def log_debug(msg: str):
    if _debug_mode:
        print(f"{Colors.DIM}[DEBUG]{Colors.NC} {msg}")


# =============================================================================
# Config Loading
# =============================================================================

def load_config() -> Dict[str, str]:
    """Load config from file, falling back to defaults."""
    config = dict(DEFAULTS)

    config_file = Path(CONFIG_PATH)
    if config_file.exists():
        log_debug(f"Loading config from {config_file}")
        with open(config_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, _, value = line.partition("=")
                    key = key.strip()
                    value = value.strip().strip('"').strip("'")
                    config[key] = value
    else:
        log_warn(f"Config file not found: {config_file}")
        log_warn("Using defaults. Create config from mdblist-sync.conf.example")

    # Also check environment variables (override file config)
    for key in DEFAULTS:
        env_val = os.environ.get(key)
        if env_val is not None:
            config[key] = env_val

    return config


# =============================================================================
# State Management
# =============================================================================

def load_state() -> dict:
    """Load sync state (which lists we manage)."""
    state_file = Path(STATE_PATH)
    if state_file.exists():
        try:
            with open(state_file) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            log_warn(f"Failed to load state: {e}")
    return {"managed_lists": {}, "last_sync": None}


def save_state(state: dict):
    """Save sync state."""
    state_file = Path(STATE_PATH)
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state["last_sync"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)
    log_debug(f"State saved to {state_file}")


# =============================================================================
# MDBList API Client
# =============================================================================

class MDBListAPI:
    """Client for MDBList.com API."""

    def __init__(self, api_key: str):
        self.api_key = api_key

    def _get(self, endpoint: str, params: Optional[dict] = None) -> any:
        """Make a GET request to the MDBList API."""
        if params is None:
            params = {}
        params["apikey"] = self.api_key
        url = f"{MDBLIST_API_BASE}{endpoint}?{urlencode(params)}"
        log_debug(f"MDBList GET: {endpoint}")

        req = Request(url)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", "mdblist-sync/1.0")
        try:
            with urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except HTTPError as e:
            if e.code == 429:
                log_error("MDBList API rate limit exceeded. Try again later.")
            else:
                log_error(f"MDBList API error: {e.code} {e.reason}")
            raise
        except URLError as e:
            log_error(f"MDBList connection error: {e.reason}")
            raise

    def get_user(self) -> dict:
        """Get user info and rate limit status."""
        return self._get("/user")

    def get_top_lists(self) -> List[dict]:
        """Get top lists sorted by Trakt likes."""
        return self._get("/lists/top")

    def search_lists(self, query: str) -> List[dict]:
        """Search public lists by title."""
        return self._get("/lists/search", {"query": query})

    def get_list_info(self, list_id: int) -> list:
        """Get list details by ID."""
        return self._get(f"/lists/{list_id}")

    def get_list_items(self, list_id: int, limit: int = 10) -> dict:
        """Get items from a list (for preview)."""
        return self._get(f"/lists/{list_id}/items", {"limit": limit})


# =============================================================================
# Arr API Client
# =============================================================================

class ArrAPI:
    """Generic API client for Radarr/Sonarr."""

    def __init__(self, url: str, api_key: str, base_url: str = ""):
        self.url = url.rstrip("/")
        self.api_key = api_key
        if base_url:
            base_url = base_url.rstrip("/")
            if not base_url.startswith("/"):
                base_url = "/" + base_url
            self.base_url = base_url
        else:
            self.base_url = ""

    def _request(self, endpoint: str, method: str = "GET", data: any = None) -> any:
        full_url = f"{self.url}{self.base_url}/api/v3{endpoint}"
        req = Request(full_url, method=method)
        req.add_header("X-Api-Key", self.api_key)
        req.add_header("Content-Type", "application/json")

        body = None
        if data is not None:
            body = json.dumps(data).encode("utf-8")
            log_debug(f"Request: {method} {full_url}")
            log_debug(f"Payload: {json.dumps(data, indent=2)}")

        try:
            with urlopen(req, data=body, timeout=30) as resp:
                raw = resp.read().decode()
                if not raw:
                    return {}
                return json.loads(raw)
        except HTTPError as e:
            # Read error body and attach to exception for caller to inspect
            error_msg = ""
            try:
                error_body = e.read().decode()
                if error_body:
                    try:
                        error_msg = json.loads(error_body)
                    except json.JSONDecodeError:
                        error_msg = error_body[:500]
            except Exception:
                pass
            e.error_detail = error_msg
            log_debug(f"Arr API error: {e.code} {e.reason} | {full_url}")
            if error_msg:
                log_debug(f"  Detail: {error_msg}")
            raise
        except URLError as e:
            log_error(f"Arr connection error: {e.reason}")
            raise

    def get_status(self) -> dict:
        return self._request("/system/status")

    def get_quality_profiles(self) -> List[dict]:
        return self._request("/qualityprofile")

    def get_root_folders(self) -> List[dict]:
        return self._request("/rootfolder")

    def get_import_lists(self) -> List[dict]:
        return self._request("/importlist")

    def add_import_list(self, payload: dict) -> dict:
        return self._request("/importlist", method="POST", data=payload)

    def delete_import_list(self, list_id: int):
        return self._request(f"/importlist/{list_id}", method="DELETE")

    def get_import_list_schema(self) -> List[dict]:
        return self._request("/importlist/schema")

    def get_sync_targets(self, all_instances: List[Tuple[str, "ArrAPI"]]) -> List[str]:
        """Get names of instances this one syncs FROM via RadarrImport/SonarrImport.
        Returns list of instance names whose URLs match sync list baseUrls."""
        # Build URL -> name mapping for all other instances
        url_to_name = {}
        for inst_name, other_api in all_instances:
            if other_api is not self:
                base = f"{other_api.url}{other_api.base_url}".rstrip("/").lower()
                url_to_name[base] = inst_name

        targets = []
        try:
            for il in self.get_import_lists():
                impl = il.get("implementation", "")
                if impl not in ("RadarrImport", "SonarrImport"):
                    continue
                for field in il.get("fields", []):
                    if field.get("name") == "baseUrl" and field.get("value"):
                        target = field["value"].rstrip("/").lower()
                        if target in url_to_name:
                            targets.append(url_to_name[target])
        except Exception:
            pass
        return targets


# =============================================================================
# Arr Instance Discovery
# =============================================================================

def discover_arr_config(instance: str) -> Optional[Tuple[str, str, str]]:
    """
    Discover *arr config from Swizzin installation.
    Returns (url, api_key, base_url) or None.
    """
    config = ARR_INSTANCES.get(instance)
    if not config:
        return None

    home = Path("/home")
    if not home.exists():
        return None

    for user_dir in home.iterdir():
        if not user_dir.is_dir():
            continue
        for config_path_template in config["config_paths"]:
            config_path = Path(config_path_template.format(user=user_dir.name))
            if config_path.exists():
                try:
                    tree = ET.parse(config_path)
                    root = tree.getroot()
                    port = root.findtext("Port")
                    api_key = root.findtext("ApiKey")
                    url_base = root.findtext("UrlBase", "")
                    if port and api_key:
                        url = f"http://localhost:{port}"
                        return (url, api_key, url_base)
                except Exception as e:
                    log_warn(f"Failed to parse {config_path}: {e}")
    return None


def discover_instances(config: Dict[str, str]) -> Tuple[List[Tuple[str, ArrAPI]], List[Tuple[str, ArrAPI]]]:
    """
    Discover all running Radarr and Sonarr instances.
    Returns (radarr_instances, sonarr_instances) as lists of (name, api) tuples.
    """
    radarr_apis = []
    sonarr_apis = []

    # Determine which instances to check
    radarr_names = [s.strip() for s in config["RADARR_INSTANCES"].split(",") if s.strip()] if config["RADARR_INSTANCES"] else [
        k for k, v in ARR_INSTANCES.items() if v["type"] == "radarr"
    ]
    sonarr_names = [s.strip() for s in config["SONARR_INSTANCES"].split(",") if s.strip()] if config["SONARR_INSTANCES"] else [
        k for k, v in ARR_INSTANCES.items() if v["type"] == "sonarr"
    ]

    for name in radarr_names:
        result = discover_arr_config(name)
        if result:
            url, api_key, base_url = result
            api = ArrAPI(url, api_key, base_url)
            try:
                status = api.get_status()
                log_success(f"Radarr '{name}' connected (v{status.get('version', '?')})")
                radarr_apis.append((name, api))
            except Exception:
                log_warn(f"Radarr '{name}' found but not reachable")

    for name in sonarr_names:
        result = discover_arr_config(name)
        if result:
            url, api_key, base_url = result
            api = ArrAPI(url, api_key, base_url)
            try:
                status = api.get_status()
                log_success(f"Sonarr '{name}' connected (v{status.get('version', '?')})")
                sonarr_apis.append((name, api))
            except Exception:
                log_warn(f"Sonarr '{name}' found but not reachable")

    return radarr_apis, sonarr_apis


# =============================================================================
# Import List Defaults
# =============================================================================

def get_radarr_defaults(api: ArrAPI, config: Dict[str, str], instance_name: str = "") -> Optional[dict]:
    """Get quality profile and root folder for Radarr import lists.
    Supports per-instance overrides via RADARR_<SUFFIX>_QUALITY_PROFILE and
    RADARR_<SUFFIX>_ROOT_FOLDER (e.g., RADARR_4K_QUALITY_PROFILE).
    """
    # Check for instance-specific config (e.g., radarr-4k -> RADARR_4K_*)
    suffix = instance_name.replace("radarr-", "").replace("radarr", "").upper()
    if suffix:
        profile_name = config.get(f"RADARR_{suffix}_QUALITY_PROFILE", "") or config["RADARR_QUALITY_PROFILE"]
        root_path = config.get(f"RADARR_{suffix}_ROOT_FOLDER", "") or config["RADARR_ROOT_FOLDER"]
    else:
        profile_name = config["RADARR_QUALITY_PROFILE"]
        root_path = config["RADARR_ROOT_FOLDER"]

    inst_label = instance_name or "Radarr"

    if not profile_name:
        profiles = api.get_quality_profiles()
        if not profiles:
            log_error(f"No quality profiles found in {inst_label}")
            return None
        profile_id = profiles[0]["id"]
        log_debug(f"Auto-selected quality profile: {profiles[0]['name']} (id={profile_id})")
    else:
        profiles = api.get_quality_profiles()
        match = next((p for p in profiles if p["name"].lower() == profile_name.lower()), None)
        if not match:
            available = ", ".join(p["name"] for p in profiles[:5])
            log_error(f"Quality profile '{profile_name}' not found in {inst_label} (available: {available})")
            return None
        profile_id = match["id"]

    if not root_path:
        folders = api.get_root_folders()
        if not folders:
            log_error(f"No root folders found in {inst_label}")
            return None
        root_path = folders[0]["path"]
        log_debug(f"Auto-selected root folder: {root_path}")

    return {
        "qualityProfileId": profile_id,
        "rootFolderPath": root_path,
        "monitor": config["RADARR_MONITOR"],
        "minimumAvailability": config["RADARR_MIN_AVAILABILITY"],
        "searchOnAdd": config["RADARR_SEARCH_ON_ADD"].lower() == "true",
    }


def get_sonarr_defaults(api: ArrAPI, config: Dict[str, str], instance_name: str = "") -> Optional[dict]:
    """Get quality profile and root folder for Sonarr import lists.
    Supports per-instance overrides via SONARR_<SUFFIX>_QUALITY_PROFILE and
    SONARR_<SUFFIX>_ROOT_FOLDER (e.g., SONARR_ANIME_QUALITY_PROFILE).
    """
    # Check for instance-specific config (e.g., sonarr-anime -> SONARR_ANIME_*)
    suffix = instance_name.replace("sonarr-", "").replace("sonarr", "").upper()
    if suffix:
        profile_name = config.get(f"SONARR_{suffix}_QUALITY_PROFILE", "") or config["SONARR_QUALITY_PROFILE"]
        root_path = config.get(f"SONARR_{suffix}_ROOT_FOLDER", "") or config["SONARR_ROOT_FOLDER"]
    else:
        profile_name = config["SONARR_QUALITY_PROFILE"]
        root_path = config["SONARR_ROOT_FOLDER"]

    inst_label = instance_name or "Sonarr"

    if not profile_name:
        profiles = api.get_quality_profiles()
        if not profiles:
            log_error(f"No quality profiles found in {inst_label}")
            return None
        profile_id = profiles[0]["id"]
        log_debug(f"Auto-selected quality profile: {profiles[0]['name']} (id={profile_id})")
    else:
        profiles = api.get_quality_profiles()
        match = next((p for p in profiles if p["name"].lower() == profile_name.lower()), None)
        if not match:
            available = ", ".join(p["name"] for p in profiles[:5])
            log_error(f"Quality profile '{profile_name}' not found in {inst_label} (available: {available})")
            return None
        profile_id = match["id"]

    if not root_path:
        folders = api.get_root_folders()
        if not folders:
            log_error(f"No root folders found in {inst_label}")
            return None
        root_path = folders[0]["path"]
        log_debug(f"Auto-selected root folder: {root_path}")

    # Auto-set series type to "anime" for anime instances
    series_type = config["SONARR_SERIES_TYPE"]
    if "anime" in instance_name and series_type == "standard":
        series_type = "anime"

    return {
        "qualityProfileId": profile_id,
        "rootFolderPath": root_path,
        "shouldMonitor": config["SONARR_MONITOR"],
        "seriesType": series_type,
        "seasonFolder": config["SONARR_SEASON_FOLDER"].lower() == "true",
        "searchForMissingEpisodes": config["SONARR_SEARCH_ON_ADD"].lower() == "true",
    }


# =============================================================================
# List Discovery
# =============================================================================

def discover_lists(mdb: MDBListAPI, config: Dict[str, str], has_anime_instance: bool = False) -> Tuple[List[dict], List[dict]]:
    """
    Discover MDBList lists worth subscribing to.
    Returns (movie_lists, show_lists) sorted by likes descending.
    When has_anime_instance is True, anime show lists bypass the likes threshold.
    """
    min_likes = int(config["MIN_LIKES"])
    min_items = int(config["MIN_ITEMS"])
    blocked = set(s.strip() for s in config["BLOCKED_LISTS"].split(",") if s.strip())

    seen_ids = set()
    all_lists = []

    # 1) Top lists (most popular)
    log("Fetching top lists from MDBList...")
    try:
        top = mdb.get_top_lists()
        for lst in top:
            if lst["id"] not in seen_ids:
                seen_ids.add(lst["id"])
                all_lists.append(lst)
        log_debug(f"  Found {len(top)} top lists")
    except Exception as e:
        log_warn(f"Failed to fetch top lists: {e}")

    # 2) Search-based discovery
    search_terms = [s.strip() for s in config["SEARCH_TERMS"].split(",") if s.strip()]
    for term in search_terms:
        log(f"Searching lists for '{term}'...")
        try:
            results = mdb.search_lists(term)
            added = 0
            for lst in results:
                if lst["id"] not in seen_ids:
                    seen_ids.add(lst["id"])
                    all_lists.append(lst)
                    added += 1
            log_debug(f"  Found {added} new lists for '{term}'")
        except Exception as e:
            log_warn(f"Failed to search for '{term}': {e}")

    # 3) Pinned lists
    pinned = [s.strip() for s in config["PINNED_LISTS"].split(",") if s.strip()]
    for list_id_str in pinned:
        try:
            list_id_int = int(list_id_str)
        except ValueError:
            log_warn(f"Invalid pinned list ID: {list_id_str}")
            continue
        if list_id_int in seen_ids:
            continue
        try:
            info = mdb.get_list_info(list_id_int)
            if isinstance(info, list):
                for lst in info:
                    if lst["id"] not in seen_ids:
                        seen_ids.add(lst["id"])
                        lst["_pinned"] = True
                        all_lists.append(lst)
            log_debug(f"  Added pinned list {list_id_str}")
        except Exception as e:
            log_warn(f"Failed to fetch pinned list {list_id_str}: {e}")

    # Filter
    movie_lists = []
    show_lists = []

    for lst in all_lists:
        list_id = str(lst["id"])
        if list_id in blocked:
            log_debug(f"  Blocked list: {lst['name']} (id={list_id})")
            continue

        likes = lst.get("likes") or 0
        items = lst.get("items") or 0
        is_pinned = lst.get("_pinned", False)
        anime = is_anime_list(lst)

        # Anime show lists use a lower likes threshold when an anime instance exists
        # (anime lists on MDBList tend to have fewer likes than mainstream lists)
        min_likes_anime = int(config.get("MIN_LIKES_ANIME", max(1, min_likes // 4)))
        if not is_pinned:
            if anime and has_anime_instance:
                if likes < min_likes_anime or items < min_items:
                    continue
            elif likes < min_likes or items < min_items:
                continue

        mediatype = lst.get("mediatype", "")
        if mediatype == "movie":
            movie_lists.append(lst)
        elif mediatype == "show":
            show_lists.append(lst)
        else:
            log_debug(f"  Skipping list '{lst.get('name', '?')}': unsupported mediatype '{mediatype}'")

    # Sort by likes descending
    movie_lists.sort(key=lambda x: x.get("likes") or 0, reverse=True)
    show_lists.sort(key=lambda x: x.get("likes") or 0, reverse=True)

    log(f"Discovered {len(movie_lists)} movie lists, {len(show_lists)} show lists (after filters)")
    return movie_lists, show_lists


# =============================================================================
# Import List URL Construction
# =============================================================================

def get_list_url(lst: dict) -> Optional[str]:
    """Build the MDBList JSON URL for a list (compatible with Radarr/Sonarr Custom Lists)."""
    username = lst.get("user_name", "")
    slug = lst.get("slug", "")
    if not username or not slug:
        log_warn(f"List '{lst.get('name', '?')}' missing username or slug, skipping")
        return None
    return f"{MDBLIST_LIST_BASE}/{username}/{slug}/json"


# =============================================================================
# Sync Logic
# =============================================================================

def get_managed_import_lists(api: ArrAPI, prefix: str) -> List[dict]:
    """Get import lists we manage (identified by name prefix)."""
    all_lists = api.get_import_lists()
    return [il for il in all_lists if il.get("name", "").startswith(prefix)]


def build_radarr_import_list(lst: dict, defaults: dict, prefix: str) -> dict:
    """Build import list payload for Radarr."""
    list_url = get_list_url(lst)
    name = f"{prefix} {lst['name']}"
    # Truncate name if too long
    if len(name) > 100:
        name = name[:97] + "..."

    return {
        "name": name,
        "enabled": True,
        "enableAuto": True,
        "searchOnAdd": defaults["searchOnAdd"],
        "monitor": defaults["monitor"],
        "minimumAvailability": defaults["minimumAvailability"],
        "qualityProfileId": defaults["qualityProfileId"],
        "rootFolderPath": defaults["rootFolderPath"],
        "listOrder": 0,
        "implementation": "RadarrListImport",
        "configContract": "RadarrListSettings",
        "listType": "advanced",
        "tags": [],
        "fields": [
            {"name": "url", "value": list_url},
        ],
    }


def build_sonarr_import_list(lst: dict, defaults: dict, prefix: str) -> dict:
    """Build import list payload for Sonarr."""
    list_url = get_list_url(lst)
    name = f"{prefix} {lst['name']}"
    if len(name) > 100:
        name = name[:97] + "..."

    return {
        "name": name,
        "enableAutomaticAdd": True,
        "searchForMissingEpisodes": defaults["searchForMissingEpisodes"],
        "shouldMonitor": defaults["shouldMonitor"],
        "monitorNewItems": "all",
        "qualityProfileId": defaults["qualityProfileId"],
        "seriesType": defaults["seriesType"],
        "seasonFolder": defaults["seasonFolder"],
        "rootFolderPath": defaults["rootFolderPath"],
        "listOrder": 0,
        "implementation": "CustomImport",
        "configContract": "CustomSettings",
        "listType": "advanced",
        "tags": [],
        "fields": [
            {"name": "baseUrl", "value": list_url},
        ],
    }


def sync_lists_to_instance(
    instance_name: str,
    api: ArrAPI,
    lists: List[dict],
    max_lists: int,
    defaults: dict,
    build_fn,
    prefix: str,
    state: dict,
    dry_run: bool,
) -> int:
    """
    Sync discovered lists to a Sonarr/Radarr instance.
    Returns number of lists added.
    """
    # Fetch all import lists once, then split into managed vs all
    all_import = api.get_import_lists()
    managed = [il for il in all_import if il.get("name", "").startswith(prefix)]

    all_urls = set()
    for il in all_import:
        for field in il.get("fields", []):
            if field.get("name") in ("url", "baseUrl") and field.get("value"):
                all_urls.add(field["value"])

    slots_available = max_lists - len(managed)
    added = 0

    for lst in lists:
        if slots_available <= 0:
            break

        list_url = get_list_url(lst)
        if not list_url:
            continue
        if list_url in all_urls:
            log_debug(f"  Already exists: {lst['name']}")
            continue

        if dry_run:
            log_dry(f"  Would add to {instance_name}: {lst['name']} ({lst.get('likes', 0)} likes, {lst.get('items', 0)} items)")
            log_dry(f"    URL: {list_url}")
        else:
            payload = build_fn(lst, defaults, prefix)
            try:
                result = api.add_import_list(payload)
                import_list_id = result.get("id", "?")
                log_success(f"  Added to {instance_name}: {lst['name']} (import_list_id={import_list_id})")

                # Track in state
                state_key = f"{instance_name}:{lst['id']}"
                state.setdefault("managed_lists", {})[state_key] = {
                    "mdblist_id": lst["id"],
                    "import_list_id": import_list_id,
                    "instance": instance_name,
                    "name": lst["name"],
                    "url": list_url,
                    "likes": lst.get("likes") or 0,
                    "items": lst.get("items") or 0,
                    "added_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
            except HTTPError as e:
                detail = getattr(e, "error_detail", "")
                if e.code == 400 and detail:
                    # Extract meaningful message from Sonarr/Radarr validation errors
                    msgs = []
                    if isinstance(detail, list):
                        msgs = [d.get("errorMessage", "") for d in detail if isinstance(d, dict)]
                    msg = msgs[0] if msgs else str(detail)
                    log_warn(f"  Skipped '{lst['name']}' on {instance_name}: {msg[:120]}")
                else:
                    log_error(f"  Failed to add '{lst['name']}' to {instance_name}: {e.code} {e.reason}")
                continue
            except Exception as e:
                log_error(f"  Failed to add '{lst['name']}' to {instance_name}: {e}")
                continue

        all_urls.add(list_url)
        slots_available -= 1
        added += 1

    return added


def cleanup_stale_lists(
    instance_name: str,
    api: ArrAPI,
    mdb: MDBListAPI,
    prefix: str,
    min_likes: int,
    state: dict,
    dry_run: bool,
) -> int:
    """Remove managed lists that have fallen below quality threshold."""
    managed = get_managed_import_lists(api, prefix)
    removed = 0

    for il in managed:
        import_id = il["id"]
        name = il.get("name", "")

        # Find the MDBList ID from state
        state_entry = None
        for key, entry in state.get("managed_lists", {}).items():
            if entry.get("import_list_id") == import_id:
                state_entry = entry
                break

        if not state_entry:
            # Unknown managed list - skip (might be manually added with same prefix)
            log_debug(f"  Skipping unknown managed list: {name}")
            continue

        # Check if list still meets criteria
        try:
            info = mdb.get_list_info(state_entry["mdblist_id"])
            if isinstance(info, list) and info:
                current_likes = info[0].get("likes") or 0
            else:
                current_likes = 0
        except Exception:
            # Can't verify, skip
            continue

        if current_likes < min_likes:
            if dry_run:
                log_dry(f"  Would remove from {instance_name}: {name} ({current_likes} likes < {min_likes} min)")
            else:
                try:
                    api.delete_import_list(import_id)
                    log_success(f"  Removed from {instance_name}: {name} ({current_likes} likes)")

                    # Remove from state
                    state_key = f"{instance_name}:{state_entry['mdblist_id']}"
                    state.get("managed_lists", {}).pop(state_key, None)
                except Exception as e:
                    log_error(f"  Failed to remove '{name}': {e}")
                    continue

            removed += 1

    return removed


# =============================================================================
# Status Display
# =============================================================================

def show_status(config: Dict[str, str], state: dict, radarr_apis, sonarr_apis):
    """Display current managed lists status."""
    prefix = config["LIST_NAME_PREFIX"]

    print(f"\n{Colors.BOLD}MDBList Auto-Sync Status{Colors.NC}")
    print(f"{'=' * 60}")

    if state.get("last_sync"):
        print(f"Last sync: {state['last_sync']}")
    else:
        print("Last sync: never")

    managed = state.get("managed_lists", {})
    print(f"Managed lists in state: {len(managed)}")

    for instance_name, api in radarr_apis + sonarr_apis:
        print(f"\n{Colors.BOLD}{instance_name}{Colors.NC}")
        try:
            import_lists = get_managed_import_lists(api, prefix)
            if not import_lists:
                print(f"  No managed import lists")
                continue

            for il in import_lists:
                name = il.get("name", "unknown")
                enabled = il.get("enabled", il.get("enableAutomaticAdd", False))
                status = f"{Colors.GREEN}enabled{Colors.NC}" if enabled else f"{Colors.RED}disabled{Colors.NC}"

                list_url = ""
                for field in il.get("fields", []):
                    if field.get("name") in ("url", "baseUrl"):
                        list_url = field.get("value", "")
                        break

                print(f"  {name}")
                print(f"    Status: {status} | URL: {list_url}")
        except Exception as e:
            print(f"  Error checking: {e}")

    print()


# =============================================================================
# Main
# =============================================================================

def main():
    global _debug_mode

    # Parse args
    args = set(sys.argv[1:])

    if "--help" in args or "-h" in args:
        print(__doc__.strip())
        sys.exit(0)

    dry_run = "--dry-run" in args
    cleanup = "--cleanup" in args
    status = "--status" in args
    _debug_mode = "--debug" in args

    if dry_run:
        log("Dry-run mode: no changes will be made")

    # Load config
    config = load_config()
    state = load_state()

    api_key = config["MDBLIST_API_KEY"]
    if not api_key:
        log_error("MDBLIST_API_KEY is required. Get one from https://mdblist.com/preferences/")
        log_error(f"Set it in {CONFIG_PATH} or via environment variable")
        sys.exit(1)

    prefix = config["LIST_NAME_PREFIX"]

    # Connect to MDBList
    mdb = MDBListAPI(api_key)
    try:
        user = mdb.get_user()
        remaining = user.get("rate_limit_remaining", "?")
        limit = user.get("rate_limit", "?")
        log_success(f"MDBList connected as '{user.get('username', '?')}' (API: {remaining}/{limit} remaining)")
    except Exception as e:
        log_error(f"Failed to connect to MDBList API: {e}")
        sys.exit(1)

    # Discover *arr instances
    radarr_apis, sonarr_apis = discover_instances(config)

    if not radarr_apis and not sonarr_apis:
        log_error("No Radarr or Sonarr instances found")
        sys.exit(1)

    # Status mode
    if status:
        show_status(config, state, radarr_apis, sonarr_apis)
        return

    # Cleanup mode
    if cleanup:
        log(f"\n{Colors.BOLD}Cleaning up stale lists...{Colors.NC}")
        cleanup_min = int(config["CLEANUP_MIN_LIKES"])
        total_removed = 0

        for name, api in radarr_apis + sonarr_apis:
            removed = cleanup_stale_lists(name, api, mdb, prefix, cleanup_min, state, dry_run)
            total_removed += removed

        if total_removed > 0:
            log_success(f"Removed {total_removed} stale lists")
            if not dry_run:
                save_state(state)
        else:
            log("No stale lists to remove")
        return

    # --- Main sync ---
    log(f"\n{Colors.BOLD}Discovering lists from MDBList...{Colors.NC}")
    has_anime_instance = any("anime" in name for name, _ in sonarr_apis)
    movie_lists, show_lists = discover_lists(mdb, config, has_anime_instance)

    max_movies = int(config["MAX_LISTS_MOVIES"])
    max_shows = int(config["MAX_LISTS_SHOWS"])
    total_added = 0

    # Sync movie lists to Radarr instances
    # Skip instances that sync from another instance (e.g., radarr-4k syncing from radarr)
    if radarr_apis and movie_lists:
        log(f"\n{Colors.BOLD}Syncing movie lists to Radarr...{Colors.NC}")
        # Determine which instances are secondary (sync from a primary)
        # If A syncs from B but B doesn't sync from A, A is secondary.
        # If bidirectional, the base instance (shorter name) is primary.
        sync_map = {n: api.get_sync_targets(radarr_apis) for n, api in radarr_apis}
        skip_radarr = set()
        for inst_name, targets in sync_map.items():
            for target in targets:
                target_syncs_back = inst_name in sync_map.get(target, [])
                if not target_syncs_back:
                    # Unidirectional: this instance is secondary
                    skip_radarr.add(inst_name)
                elif len(inst_name) > len(target):
                    # Bidirectional: longer name (e.g., radarr-4k) is secondary
                    skip_radarr.add(inst_name)

        for name, api in radarr_apis:
            if name in skip_radarr:
                log(f"  Skipping {name}: syncs from another instance")
                continue

            defaults = get_radarr_defaults(api, config, name)
            if not defaults:
                log_warn(f"Skipping {name}: could not determine defaults")
                continue

            added = sync_lists_to_instance(
                name, api, movie_lists, max_movies, defaults,
                build_radarr_import_list, prefix, state, dry_run,
            )
            total_added += added
            log(f"  {name}: {added} lists added")

    # Sync show lists to Sonarr instances
    # Route anime lists to anime instances, non-anime to regular instances
    # Skip instances that sync from another instance (e.g., sonarr-4k syncing from sonarr)
    if sonarr_apis and show_lists:
        log(f"\n{Colors.BOLD}Syncing show lists to Sonarr...{Colors.NC}")
        has_anime_instance = any("anime" in name for name, _ in sonarr_apis)

        if has_anime_instance:
            anime_shows = [lst for lst in show_lists if is_anime_list(lst)]
            regular_shows = [lst for lst in show_lists if not is_anime_list(lst)]
            log_debug(f"  Split: {len(anime_shows)} anime lists, {len(regular_shows)} regular lists")
        else:
            anime_shows = []
            regular_shows = show_lists

        # Determine which Sonarr instances are secondary
        sync_map = {n: api.get_sync_targets(sonarr_apis) for n, api in sonarr_apis}
        skip_sonarr = set()
        for inst_name, targets in sync_map.items():
            for target in targets:
                target_syncs_back = inst_name in sync_map.get(target, [])
                if not target_syncs_back:
                    skip_sonarr.add(inst_name)
                elif len(inst_name) > len(target):
                    skip_sonarr.add(inst_name)

        for name, api in sonarr_apis:
            if name in skip_sonarr:
                log(f"  Skipping {name}: syncs from another instance")
                continue

            defaults = get_sonarr_defaults(api, config, name)
            if not defaults:
                log_warn(f"Skipping {name}: could not determine defaults")
                continue

            # Anime instances get anime lists, regular instances get the rest
            instance_lists = anime_shows if "anime" in name else regular_shows

            added = sync_lists_to_instance(
                name, api, instance_lists, max_shows, defaults,
                build_sonarr_import_list, prefix, state, dry_run,
            )
            total_added += added
            log(f"  {name}: {added} lists added")

    # Summary
    print()
    if total_added > 0:
        log_success(f"Sync complete: {total_added} new lists added")
        if not dry_run:
            save_state(state)
    else:
        log("Sync complete: no new lists to add (all up to date)")

    # Show rate limit status
    try:
        user = mdb.get_user()
        remaining = user.get("rate_limit_remaining", "?")
        log(f"MDBList API requests remaining: {remaining}")
    except Exception:
        pass


if __name__ == "__main__":
    main()
