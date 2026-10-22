#!/usr/bin/env python3
"""
Media Common Module
Shared utilities for media-to-downloads.py and media-library-sync.py.

Contains:
- Quality scoring and deduplication
- Title/year extraction and parsing
- TMDB/TVDB API clients with caching
- *arr API client and monitored content tracking
- Content filtering (language, AI upscale, etc.)
- Logging utilities
- ReleaseFolder class
"""

import json
import os
import re
import sys
import time
import unicodedata
import urllib.request
import urllib.parse
import urllib.error
import xml.etree.ElementTree as ET
from difflib import SequenceMatcher
from pathlib import Path
from threading import Lock
from typing import Dict, List, Optional, Set, Tuple

# =============================================================================
# Configuration
# =============================================================================

# Site-specific layout (mount roots, which *arr instances exist and which
# library folders they own) lives in a JSON file kept out of git:
#   $MEDIA_TOOLS_CONFIG, default /opt/swizzin-extras/media-tools.json
# See configs/media-tools.json.example. Without it, a single Radarr + Sonarr
# with "movies"/"series" folders is assumed.
MEDIA_TOOLS_CONFIG_PATH = os.environ.get("MEDIA_TOOLS_CONFIG", "/opt/swizzin-extras/media-tools.json")


def _load_media_tools_config() -> dict:
    try:
        with open(MEDIA_TOOLS_CONFIG_PATH) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}


MEDIA_TOOLS_CONFIG = _load_media_tools_config()

ZURG_BASE = Path(MEDIA_TOOLS_CONFIG.get("zurg_base", "/mnt/zurg"))
TORBOX_BASE = Path(MEDIA_TOOLS_CONFIG.get("torbox_base", "/mnt/torbox"))
SYMLINKS_BASE = Path(MEDIA_TOOLS_CONFIG.get("symlinks_base", "/mnt/symlinks"))
DOWNLOADS_BASE = Path(MEDIA_TOOLS_CONFIG.get("downloads_base", str(SYMLINKS_BASE / "downloads")))

# Mapping: zurg folder -> (download folder / instance, app type)
FOLDER_MAPPINGS = {
    folder: tuple(value)
    for folder, value in MEDIA_TOOLS_CONFIG.get("folder_mappings", {
        "movies": ["radarr", "movie"],
        "series": ["sonarr", "series"],
    }).items()
}

# *arr instance configuration for monitored content filtering. An entry may
# omit config_paths; it then defaults to ~{user}/.config/<instance>/config.xml.
_DEFAULT_ARR_INSTANCES = {
    "radarr": {"type": "radarr", "config_paths": ["/home/{user}/.config/Radarr/config.xml"]},
    "sonarr": {"type": "sonarr", "config_paths": ["/home/{user}/.config/Sonarr/config.xml"]},
}
ARR_INSTANCES = {
    name: {
        "type": spec["type"],
        "config_paths": spec.get("config_paths") or [f"/home/{{user}}/.config/{name}/config.xml"],
    }
    for name, spec in MEDIA_TOOLS_CONFIG.get("arr_instances", _DEFAULT_ARR_INSTANCES).items()
}

# Media file extensions
MEDIA_EXTENSIONS = {'.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.flv', '.webm', '.ts', '.m2ts'}

# Parallel processing settings
MAX_WORKERS = 20

# =============================================================================
# Quality Scoring
# =============================================================================

QUALITY_SCORES = {
    # === Source (highest impact) ===
    'remux': 100,
    # 'BDRemux' is one word, so \bremux\b never matches it and these
    # releases scored resolution-only (a 1080p BDRemux = 40, below the guard's floor).
    'bdremux': 100, 'bd-remux': 100,
    'bluray': 80, 'blu-ray': 80, 'blu ray': 80,
    'webdl': 60, 'web-dl': 60, 'web dl': 60,
    'webrip': 50, 'web-rip': 50, 'web rip': 50,
    'hdtv': 40,
    'bdrip': 35, 'brrip': 35,
    'dvdrip': 30, 'dvd': 30,
    'sdtv': 20,
    'dvdscr': 15, 'screener': 10, 'scr': 10,
    'hdts': 8, 'telesync': 5, 'ts': 5, 'cam': 5,

    # === Resolution ===
    '2160p': 50, '4k': 50, 'uhd': 50,
    '1080p': 40, 'fullhd': 40,
    '1080i': 35,
    '720p': 30,
    '576p': 20, '480p': 20,
    '360p': 10,

    # === Audio Codec ===
    'truehd': 30,
    'dts-hd ma': 28, 'dts-hd': 25, 'dtshd': 25, 'dts hd': 25,
    'dts-x': 27, 'dtsx': 27, 'dts x': 27,
    'atmos': 25,
    'lpcm': 22, 'pcm': 20,
    'flac': 20,
    'dts': 15,
    'dd+': 15, 'ddp': 15, 'eac3': 15, 'e-ac-3': 15, 'e-ac3': 15,
    'opus': 12,
    'dd': 10, 'ac3': 10, 'ac-3': 10,
    'aac': 10,
    'mp3': 5,

    # === Audio Channels ===
    '7.1': 12,
    '5.1': 10,
    '2.0': 5,
    'stereo': 5,
    'mono': 2,

    # === HDR Formats ===
    'dv': 35, 'dolby vision': 35, 'dolbyvision': 35, 'dovi': 35,
    'hdr10+': 30, 'hdr10plus': 30,
    'hdr10': 25,
    'hdr': 20,
    'hlg': 15,
    'wcg': 5,
    'sdr': 0,

    # === Video Codec ===
    'av1': 20,
    'hevc': 15, 'h.265': 15, 'h265': 15, 'x265': 15,
    'avc': 10, 'h.264': 10, 'h264': 10, 'x264': 10,
    'vc-1': 5, 'vc1': 5,
    'mpeg2': 3, 'mpeg-2': 3,
    'xvid': 2, 'divx': 2,

    # === Bit Depth ===
    '12bit': 10, '12-bit': 10,
    '10bit': 8, '10-bit': 8,
    '8bit': 0, '8-bit': 0,

    # === PROPER/REAL/REPACK ===
    'proper': 25,
    'real': 25,
    'repack': 20,
    'rerip': 15,

    # === Special indicators ===
    'internal': 5,
    'hybrid': 15,

    # === 3D ===
    '3d': 5,
    'sbs': 3,
    'hsbs': 3,
    'hou': 3,
}

# Edition tags - files with different editions are NOT duplicates
EDITION_TAGS = {
    'extended', 'extended cut', 'extended edition',
    'directors cut', "director's cut", 'directors edition',
    'theatrical', 'theatrical cut', 'theatrical edition',
    'unrated', 'uncut',
    'final cut', 'ultimate cut', 'redux',
    'remastered', 'restored', '4k remaster', '4k restoration',
    'imax', 'imax edition',
    'special edition', 'collectors edition', "collector's edition",
    'anniversary edition', 'anniversary',
    'definitive edition', 'definitive cut',
    'black and chrome', 'black & chrome',
    'snyder cut',
    'criterion collection', 'criterion',
    'arrow video', 'arrow',
    'shout factory', 'scream factory',
    'kino lorber',
    'masters of cinema', 'moc',
    'eureka',
    'vinegar syndrome',
    '88 films',
    'indicator',
    'imprint',
    'open matte',
    'workprint',
    'assembly cut',
    'rough cut',
    'international',
    'us version', 'uk version',
}

# AI upscale patterns - filter these out (not original quality)
AI_UPSCALE_PATTERNS = [
    r'\bAI[\.\s\-_]?UPSCALE[D]?\b',
    r'\bUPSCALE[D]?[\.\s\-_]?AI\b',
    r'\bAI[\.\s\-_]?ENHANCED\b',
    r'\bAI[\.\s\-_]?REMASTER\b',
    r'\bNEURAL[\.\s\-_]?UPSCALE\b',
    r'\bTOPAZ[\.\s\-_]?AI\b',
]
AI_UPSCALE_REGEX = re.compile('|'.join(AI_UPSCALE_PATTERNS), re.IGNORECASE)

# Language tag to ISO 639-1 code mapping
LANGUAGE_TAG_TO_CODE = {
    "french": "fr",
    "german": "de",
    "italian": "it",
    "spanish": "es",
    "japanese": "ja",
    "korean": "ko",
    "chinese": "zh",
    "russian": "ru",
    "portuguese": "pt",
    "dutch": "nl",
    "swedish": "sv",
    "norwegian": "no",
    "danish": "da",
    "finnish": "fi",
    "polish": "pl",
    "turkish": "tr",
    "arabic": "ar",
    "hindi": "hi",
    "thai": "th",
}

# =============================================================================
# TMDB/TVDB API Configuration
# =============================================================================

TMDB_API_KEY = os.environ.get("TMDB_API_KEY", "")
TMDB_BASE_URL = "https://api.themoviedb.org/3"

TVDB_API_KEY = os.environ.get("TVDB_API_KEY", "")
TVDB_BASE_URL = "https://api4.thetvdb.com/v4"
_tvdb_token: Optional[str] = None
_tvdb_token_lock = Lock()

# Cache for TMDB/TVDB lookups
_tmdb_cache: Dict[str, Optional["TMDBResult"]] = {}
_tmdb_cache_lock = Lock()
_tvdb_cache: Dict[str, Optional["TVDBResult"]] = {}
_tvdb_cache_lock = Lock()

# =============================================================================
# Terminal Colors and Logging
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


def log_skip(msg: str):
    print(f"{Colors.MAGENTA}[SKIP]{Colors.NC} {msg}")


def log_filter(msg: str):
    print(f"{Colors.DIM}[FILTER]{Colors.NC} {msg}")


_progress_lock = Lock()
_last_progress_update = [0]


def log_progress(current: int, total: int, msg: str = ""):
    """Thread-safe progress display with rate limiting."""
    now = time.time()
    with _progress_lock:
        if current < total and (now - _last_progress_update[0]) < 0.1:
            return
        _last_progress_update[0] = now
        pct = (current / total * 100) if total > 0 else 0
        print(f"\r{Colors.DIM}[{current}/{total}]{Colors.NC} {pct:.0f}% {msg[:60]:<60}", end="", flush=True)


# =============================================================================
# API Result Classes
# =============================================================================

class TMDBResult:
    """Result from TMDB search."""
    def __init__(self, title: str, year: str, original_language: str, tmdb_id: int):
        self.title = title
        self.year = year
        self.original_language = original_language
        self.tmdb_id = tmdb_id

    def __repr__(self):
        return f"TMDBResult({self.title}, {self.year}, {self.original_language})"


class TVDBResult:
    """Result from TVDB search."""
    def __init__(self, title: str, year: str, original_language: str, tvdb_id: int):
        self.title = title
        self.year = year
        self.original_language = original_language
        self.tvdb_id = tvdb_id

    def __repr__(self):
        return f"TVDBResult({self.title}, {self.year}, {self.original_language})"


# =============================================================================
# Quality Scoring Functions
# =============================================================================

def normalize_text(text: str) -> str:
    """Normalize text for matching."""
    return text.lower().replace('_', ' ').replace('.', ' ').replace('-', ' ')


# Bare `WEB` (no `-DL`) is the scene/WDX standard for lossless streaming pulls
# (`WEB.H264`, `WEB.H265`, `1080p.WEB`-trailing-codec). It's the same quality
# tier as P2P-convention `WEB-DL`, and Sonarr/Radarr's parsers already bucket
# it as WEBDL. The local QUALITY_SCORES dict only matched `webdl`/`web-dl`,
# so scene-tagged proper rips silently lost 60 points and risked falling
# below the min_score threshold (especially on 4K where min_score=70).
# Mirror Sonarr's QualityParser.cs webdl group: bare WEB followed by a codec/
# audio token, or sandwiched between resolution and codec, counts as WEB-DL.
# Deliberately does NOT match WEBRip (right word-boundary stops on the R/D).
_SCENE_BARE_WEB_TO_WEBDL_RE = re.compile(
    r'\bWEB\b(?=[\s\.\-_]+(?:[xh][\s\.\-_]?26[45]|AVC|HEVC|H[\s\.\-_]?26[45]|'
    r'DDP?[\s\.\-_]?[257][\s\.\-_]?[01]?|TrueHD|Atmos|FLAC|AAC|Opus))',
    re.IGNORECASE,
)
_RESOLUTION_BARE_WEB_RE = re.compile(
    r'\b(2160p|1080p|720p|480p)([\s\.\-_]+)WEB\b(?![\s\.\-_]+(?:DL|Rip))',
    re.IGNORECASE,
)


def _normalize_scene_web(text: str) -> str:
    """Rewrite scene-style bare `WEB` source tags to `WEB-DL` for scoring/parsing.

    Mirrors the Sonarr/Radarr parser behaviour so the local quality-scoring
    module agrees with the arr's bucket assignment. Idempotent on text that
    already contains WEB-DL/WEBDL/WEBRip.
    """
    text = _SCENE_BARE_WEB_TO_WEBDL_RE.sub('WEB-DL', text)
    text = _RESOLUTION_BARE_WEB_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}WEB-DL", text)
    return text


def calculate_quality_score(text: str) -> int:
    """Calculate quality score from text (folder/file name)."""
    score = 0
    normalized = normalize_text(_normalize_scene_web(text))
    matched = set()

    for tag, tag_score in QUALITY_SCORES.items():
        tag_normalized = tag.replace('-', ' ').replace('.', ' ')
        if tag_normalized in matched:
            continue

        pattern = r'\b' + re.escape(tag).replace(r'\ ', r'[\s\.\-_]?') + r'\b'
        if re.search(pattern, normalized, re.IGNORECASE):
            score += tag_score
            matched.add(tag_normalized)

    return score


def extract_edition(text: str) -> Optional[str]:
    """Extract edition tag from text if present."""
    lower = normalize_text(text)

    # Check for edition in curly braces (Radarr format)
    edition_match = re.search(r'\{edition-([^}]+)\}', text.lower())
    if edition_match:
        edition = edition_match.group(1).strip()
        for tag in EDITION_TAGS:
            if tag in edition:
                return tag

    # Check in text directly
    for tag in sorted(EDITION_TAGS, key=len, reverse=True):
        pattern = r'[\s\.\-_\[\(]' + re.escape(tag).replace(r'\ ', r'[\s\.\-_]') + r'[\s\.\-_\]\)]|^' + re.escape(tag).replace(r'\ ', r'[\s\.\-_]') + r'[\s\.\-_\]\)]'
        if re.search(pattern, lower):
            return tag

    return None


def get_quality_summary(text: str) -> str:
    """Get brief quality summary for display."""
    parts = []
    lower = normalize_text(_normalize_scene_web(text))

    for res, label in [('2160p', '2160P'), ('4k', '4K'), ('uhd', '2160P'),
                       ('1440p', '1440P'), ('1080p', '1080P'), ('1080i', '1080I'),
                       ('720p', '720P'), ('576p', '576P'), ('480p', '480P')]:
        if res in lower:
            parts.append(label)
            break

    for src, label in [('remux', 'REMUX'), ('bluray', 'BluRay'), ('webdl', 'WEB-DL'),
                       ('web-dl', 'WEB-DL'), ('webrip', 'WEBRip'), ('hdtv', 'HDTV')]:
        if src in lower.replace('-', '').replace(' ', ''):
            parts.append(label)
            break

    for hdr, label in [('dolby vision', 'DV'), ('dolbyvision', 'DV'), ('dovi', 'DV'),
                       ('hdr10+', 'HDR10+'), ('hdr10plus', 'HDR10+'),
                       ('hdr10', 'HDR10'), ('hdr', 'HDR')]:
        if hdr in lower.replace(' ', ''):
            parts.append(label)
            break
    else:
        # Check DV with word boundary to avoid dvdrip/dvd false positives
        if re.search(r'\bdv\b', lower):
            parts.append('DV')

    # Audio codec
    audio_lower = lower.replace('-', ' ').replace('.', ' ')
    for audio, label in [('truehd', 'TrueHD'), ('atmos', 'Atmos'), ('dts x', 'DTS-X'),
                         ('dts hd ma', 'DTS-HD MA'), ('dts hd', 'DTS-HD'),
                         ('lpcm', 'LPCM'), ('flac', 'FLAC'),
                         ('ddp', 'DD+'), ('dd+', 'DD+'), ('eac3', 'DD+'),
                         ('dd', 'DD'), ('ac3', 'DD'), ('aac', 'AAC')]:
        if audio in audio_lower:
            parts.append(label)
            break

    return ' '.join(parts) if parts else 'Unknown'


def is_multi_release(text: str) -> bool:
    """Check if release is a MULTI (multi-language) release."""
    return bool(re.search(r'[\.\s\-_]MULTI[\.\s\-_]', text, re.IGNORECASE))


def is_remux_quality(text: str) -> bool:
    """Check if release is REMUX quality."""
    return bool(re.search(r'[\.\s\-_]REMUX[\.\s\-_]', text, re.IGNORECASE))


def get_resolution_rank(text: str) -> int:
    """Extract resolution rank from text. Higher = better.
    Specific resolution tags (2160p, 1080p) take priority over
    format indicators (uhd, 4k) to handle 'UHD BluRay 1080p' correctly.
    """
    lower = text.lower()
    if '2160p' in lower: return 4
    if '1440p' in lower: return 3
    if '1080p' in lower: return 3
    if '1080i' in lower: return 3
    if '720p' in lower: return 2
    if '576p' in lower or '480p' in lower: return 1
    # Format indicators only as fallback (no explicit resolution found)
    if '4k' in lower or 'uhd' in lower: return 4
    return 0


# =============================================================================
# Title Parsing Functions
# =============================================================================

def strip_torrent_prefix(folder_name: str) -> str:
    """
    Strip common torrent site prefixes and bracketed tags from folder names.
    """
    result = folder_name

    # Pattern 1: www.site.tld followed by separator
    result = re.sub(r'^(?:www\.)?[a-zA-Z0-9\-]+\.(?:org|com|net|info|to|cc|cd|ws|me|xyz|band|club|site|online|tv|io|co|eu|ru|se|pl|cz|sk|hu)\s*(?:-\s*|\s{2,})', '', result, flags=re.IGNORECASE)

    # Pattern 1b: Known torrent site names
    known_sites = r'^(?:TheMoviesBoss|TorrentLeech|PublicHD|YIFY|YTS|ETRG|EVO|FGT|RARBG|Tigole|QxR|UTR)\s*-\s*'
    result = re.sub(known_sites, '', result, flags=re.IGNORECASE)

    # Pattern 2: Strip leading bracketed prefixes
    while True:
        match = re.match(r'^\[\s*[^\]]+\s*\][\.\s\-_]*', result)
        if match:
            result = result[match.end():].strip()
        else:
            break

    # Pattern 3: Strip content rating prefixes
    result = re.sub(r'^\d{1,2}\+[\.\s\-_]+', '', result)

    # Pattern 4: Strip numbered prefixes
    result = re.sub(r'^\d{1,3}\.\s+', '', result)
    result = re.sub(r'^\d{1,3}\s+-\s+', '', result)

    # Pattern 5: Strip short prefixes
    result = re.sub(r'^[a-z]{2,4}-(?=[A-Z])', '', result)

    return result.strip()


def strip_country_suffix(title: str) -> str:
    """Strip country suffixes from titles."""
    title = re.sub(r'\s+US$', '', title)
    title = re.sub(r'\s+UK$', '', title)
    title = re.sub(r'\.(US|UK)$', '', title)
    title = re.sub(r'\s*\((US|UK)\)$', '', title, flags=re.IGNORECASE)
    return title.strip()


def strip_episode_from_title(title: str) -> str:
    """Strip episode indicators and everything after from title."""
    result = re.sub(r'\s*[Ss]\d{1,2}[Ee]\d{1,3}.*$', '', title)
    result = re.sub(r'\s*\d{1,2}[Xx]\d{1,3}.*$', '', result)
    result = re.sub(r'\s*[Ss]\d{1,2}\b.*$', '', result)
    result = re.sub(r'\s*[-\s]*(?:Complete\s+)?Season\s*\d+.*$', '', result, flags=re.IGNORECASE)
    result = re.sub(r'\s+(?:REPACK|PROPER)$', '', result, flags=re.IGNORECASE)
    result = re.sub(r'[\s\-]+$', '', result)
    return result.strip()


def strip_edition_from_title(title: str) -> str:
    """Strip common edition tags from title for cleaner lookup."""
    edition_keywords = [
        r'\s+EXTENDED\s*(?:CUT|EDITION|VERSION)?$',
        r'\s+UNRATED\s*(?:CUT|EDITION|VERSION)?$',
        r'\s+UNCUT$',
        r'\s+THEATRICAL\s*(?:CUT|EDITION|VERSION)?$',
        r'\s+DIRECTOR\'?S?\s*(?:CUT|EDITION|VERSION)?$',
        r'\s+FINAL\s*CUT$',
        r'\s+ULTIMATE\s*(?:CUT|EDITION)?$',
        r'\s+REDUX$',
        r'\s+REMASTERED$',
        r'\s+RESTORED$',
        r'\s+IMAX\s*(?:EDITION)?$',
        r'\s+SPECIAL\s*EDITION$',
        r'\s+CRITERION\s*(?:COLLECTION)?$',
        r'\s+OPEN\s*MATTE$',
    ]

    result = title
    for pattern in edition_keywords:
        result = re.sub(pattern, '', result, flags=re.IGNORECASE)

    return result.strip()


def strip_brackets_from_title(title: str) -> str:
    """Strip bracketed content from title."""
    result = re.sub(r'\s*\[[^\]]*\]', '', title)
    result = re.sub(r'\s*\{[^\}]*\}', '', result)
    return result.strip()


def clean_title_for_search(title: str) -> str:
    """Clean title for TMDB search."""
    result = title

    # Normalize unicode characters
    result = re.sub(r'[꞉：﹕︓]', ':', result)
    result = re.sub(r'[–—―‒]', '-', result)
    result = re.sub(r'[''‚]', "'", result)
    result = re.sub(r'[""„]', '"', result)

    # Strip parentheticals with non-ASCII
    result = re.sub(r'\s*\([^)]*[^\x00-\x7F][^)]*\)', '', result)

    # Strip "+ Extras" or "- Extras"
    result = re.sub(r'\s*[\+\-]\s*Extras?\b.*$', '', result, flags=re.IGNORECASE)

    # Strip quality words
    quality_words = [
        r'\s+IMAX\b', r'\s+3D\b', r'\s+HDR\b', r'\s+SDR\b',
        r'\s+UHD\b', r'\s+4K\b', r'\s+DV\b', r'\s+REMUX\b',
        r'\s+HYBRID\b', r'\s+REMASTERED\b', r'\s+RESTORED\b',
    ]
    for pattern in quality_words:
        result = re.sub(pattern, '', result, flags=re.IGNORECASE)

    result = re.sub(r'\s+\d{4}\s*$', '', result)

    return result.strip()


def extract_title_year(folder_name: str) -> Tuple[Optional[str], Optional[str]]:
    """
    Extract title and year from folder name.
    Returns (title, year) or (None, None) if invalid.
    """
    clean_name = strip_torrent_prefix(folder_name)

    # Strip quality info in parentheses
    clean_name = re.sub(
        r'\s*\([^)]*(?:rip|1080p?|720p?|2160p?|4k|uhd|hevc|x264|x265|multisub|bluray|webdl|webrip)[^)]*\)',
        '', clean_name, flags=re.IGNORECASE
    )

    clean_name = re.sub(r'\s*\[\s*$', '', clean_name)

    # Pattern 0: Concatenated year
    match = re.match(r'^([A-Za-z][A-Za-z\s\._-]+?)(\d{4})(?:[\._\s]|$)', clean_name)
    if match:
        title = match.group(1).strip()
        year = match.group(2)
        year_int = int(year)
        if 1900 <= year_int <= 2035 and len(title) >= 2:
            title = re.sub(r'[\._]', ' ', title).strip()
            title = strip_country_suffix(title)
            title = re.sub(
                r'\s+(?:IMAX|EXTENDED(?:\s+CUT)?|UNRATED(?:\s+CUT)?|DIRECTOR\'?S?\s*CUT|'
                r'THEATRICAL(?:\s+CUT)?|REMASTERED|SPECIAL\s*EDITION|CRITERION|REDUX|UNCUT|'
                r'FINAL\s+CUT|ULTIMATE\s+(?:CUT|EDITION))$',
                '', title, flags=re.IGNORECASE
            )
            return title, year

    # Pattern 1: Year in parentheses
    match = re.match(r'^(.+?)\s*\((\d{4})\)', clean_name)
    if match:
        title = match.group(1).strip()
        year = match.group(2)
        title = re.sub(r'[\._]', ' ', title).strip()
        title = re.sub(r'\s+(?:IMAX|EXTENDED|UNRATED|DIRECTOR\'?S?\s*CUT|THEATRICAL|REMASTERED|SPECIAL\s*EDITION|CRITERION|REDUX|UNCUT)$', '', title, flags=re.IGNORECASE)
        title = strip_country_suffix(title)
        return title, year

    # Pattern 2: Find years before quality tags
    quality_pattern = r'(?:^|[\.\s\-_])(2160p?|1080p?|720p?|480p|4K|UHD|BluRay|Blu-Ray|BDRemux|WEB-DL|WEBRip|HDTV|REMUX|HDR10\+?|HDR|SDR|DTS-HD|DTS|DD[P\+]?[25]|Atmos|HEVC|x265|x264|H\.?264|H\.?265|AVC|HYBRID|TrueHD|ATVP|NF|AMZN|DSNP)(?:[\.\s\-_]|$)'

    quality_match = re.search(quality_pattern, clean_name, re.IGNORECASE)
    search_portion = clean_name[:quality_match.start()] if quality_match else clean_name

    year_candidates = []
    for match in re.finditer(r'\b(\d{4})\b', search_portion):
        year_str = match.group(1)
        year_int = int(year_str)
        if 1900 <= year_int <= 2035:
            year_candidates.append((year_str, match.start(), match.end()))

    if year_candidates:
        year, year_start, year_end = year_candidates[-1]

        title = clean_name[:year_start].strip()
        title = re.sub(r'[\._]', ' ', title).strip()
        title = re.sub(r'[\s\.\-_]+$', '', title)
        title = strip_country_suffix(title)
        title = re.sub(
            r'\s+(?:IMAX|EXTENDED(?:\s+CUT)?|UNRATED(?:\s+CUT)?|DIRECTOR\'?S?\s*CUT|'
            r'THEATRICAL(?:\s+CUT)?|REMASTERED|SPECIAL\s*EDITION|CRITERION|REDUX|UNCUT|'
            r'FINAL\s+CUT|ULTIMATE\s+(?:CUT|EDITION))$',
            '', title, flags=re.IGNORECASE
        )

        if len(title) >= 1 and re.search(r'[a-zA-Z]', title):
            return title, year

    return None, None


def extract_title_without_year(folder_name: str) -> Optional[str]:
    """Extract title from folder name without requiring a year."""
    clean_name = strip_torrent_prefix(folder_name)

    clean_name = re.sub(
        r'\s*\([^)]*(?:rip|1080p?|720p?|2160p?|4k|uhd|hevc|x264|x265|multisub|bluray|webdl|webrip)[^)]*\)',
        '', clean_name, flags=re.IGNORECASE
    )

    clean_name = re.sub(r'\s*\[\s*$', '', clean_name)

    quality_pattern = r'(?:^|[\.\s\-_])(2160p?|1080p?|720p?|480p|4K|UHD|BluRay|Blu-Ray|BDRemux|WEB-DL|WEBRip|HDTV|REMUX|HDR10\+?|HDR|SDR|DTS-HD|DTS|DD[P\+]?[25]|Atmos|HEVC|x265|x264|H\.?264|H\.?265|AVC|HYBRID|TrueHD|DVDRip|BRRip|ATVP|NF|AMZN|DSNP)(?:[\.\s\-_]|$)'

    quality_match = re.search(quality_pattern, clean_name, re.IGNORECASE)
    if quality_match:
        title = clean_name[:quality_match.start()].strip()
        title = re.sub(r'[\._]', ' ', title).strip()
        title = re.sub(r'[\s\.\-_]+$', '', title)
        title = strip_country_suffix(title)

        if len(title) >= 2 and re.search(r'[a-zA-Z]', title):
            return title

    return None


def extract_aka_titles(folder_name: str) -> List[str]:
    """Extract alternative titles from AKA format."""
    clean_name = strip_torrent_prefix(folder_name)

    patterns = [
        r'^(.+?)\s+AKA\s+(.+?)(?:\s+S\d{1,2}|\s+Season|\s+\(|\s+\d{4}|$)',
        r'^(.+?)\.aka\.(.+?)(?:\.S\d{1,2}|\.Season|\.|\s|$)',
    ]

    for pattern in patterns:
        match = re.match(pattern, clean_name, re.IGNORECASE)
        if match:
            title1 = match.group(1).strip()
            title2 = match.group(2).strip()
            title1 = re.sub(r'[\._]', ' ', title1).strip()
            title2 = re.sub(r'[\._]', ' ', title2).strip()
            if title1 and title2:
                return [title1, title2]

    return []


def extract_series_title(folder_name: str) -> Optional[str]:
    """
    Extract title from scene-style series naming.
    Returns title or None if no match.
    """
    clean_name = strip_torrent_prefix(folder_name)

    # Strip non-ASCII parentheticals
    clean_name = re.sub(r'\s*\([^)]*[^\x00-\x7F][^)]*\)', '', clean_name)

    # Strip anime tags
    clean_name = re.sub(r'\s*\((?:Anime|Movie|OVA|Special)(?:\+[^)]+)?\)', '', clean_name, flags=re.IGNORECASE)
    clean_name = re.sub(r'\s*\(Season\s+\d+\s*[\+\-]\s*(?:Season\s+)?\d+\)', '', clean_name, flags=re.IGNORECASE)
    # Strip "(Season 01-25+Movies)" style batch info
    clean_name = re.sub(r'\s*\(Season\s+\d+[-+][^)]*\)', '', clean_name, flags=re.IGNORECASE)
    # Strip "(The Final Season Part X)" style anime season names
    clean_name = re.sub(r'\s*\(The\s+(?:Final\s+)?Season(?:\s+Part\s*\d+)?\)', '', clean_name, flags=re.IGNORECASE)
    clean_name = re.sub(r'\s*\[(?:Dual\s*Audio|BD|DVD|WEB|BluRay|\d{3,4}p)[^\]]*\]\s*$', '', clean_name, flags=re.IGNORECASE)
    clean_name = re.sub(r'\s*\[(?:Dual\s*Audio|BD|DVD|WEB|BluRay|\d{3,4}p)[^\]]*\]\s*$', '', clean_name, flags=re.IGNORECASE)

    # FIX 4: Strip unbracketed quality patterns like "1080p Dual Audio BDRip x265-EMBER"
    clean_name = re.sub(
        r'\s+\d{3,4}p\s+(?:Dual\s*Audio\s+)?(?:BD|BluRay|DVD|WEB|HDTV|BDRip|WEBRip|REMUX|NF|AMZN|DSNP)[^\[\]]*$',
        '', clean_name, flags=re.IGNORECASE
    )
    # Strip release group suffix: "-EMBER", "-TTGA", "-FHC", etc.
    clean_name = re.sub(r'-[A-Z0-9]{2,10}$', '', clean_name, flags=re.IGNORECASE)

    patterns = [
        # Anime movie subtitle patterns
        r'^([A-Za-z][A-Za-z0-9\s\.]+?)\s+-\s+[A-Z][a-z].*?\s+-\s+Movie\s*\d+',
        r'^([A-Za-z][A-Za-z0-9\s\.]+?)\s+-\s+[A-Z][a-z]+(?:\s+(?:no|ni|wa|ga|wo|de|to)\s+|\s+)[A-Z][a-z]+\s*[\[\(]',

        # Version suffix patterns
        r'^(.+?)\s+-\s+[Ss]\d{1,2}(?:v\d+)[\s\[\(]',
        r'^(.+?)[\.\s\-_][Ss]\d{1,2}(?:v\d+)[\.\s\-_\[\(]',

        # S01E01 patterns
        r'^(.+?)\s+-\s+[Ss]\d{1,2}[Ee]\d{1,3}',
        r'^(.+?)[\.\s\-_][Ss]\d{1,2}[Ee]\d{1,3}',
        r'^(.+?)[\.\s\-_]\d{1,2}[Xx]\d{1,3}',
        r'^(.+?)[\.\s\-_][Ss]\d{1,2}[\.\s\-_\+]',
        r'^(.+?)[\.\s\-_][Ss]\d{1,2}$',
        r'^(.+?)\s+[Ss]\d{1,2}[Ee]\d{1,3}\s',
        r'^(.+?)[\.\s\-_]Season[\.\s\-_]*\d+',
        r'^(.+?)\s+Season\s*\d+',

        # Anime-style patterns
        r'^(.+?)\s+-\s+(?:Episode|Ep\.?)\s*\d+',
        r'^(.+?)\s+-\s+Movie\s*\d+',
        r'^(.+?)\s+[Ss]\d{1,2}\s+-\s+\d{1,4}',
        r'^(.+?)\s+Episode\s+\d+\s*-\s*\d+',
        r'^(.+?)\s+-\s+\d{1,4}(?:v\d+)?\s*[\[\(]',
        r'^(.+?)\s+-\s+\d{1,4}(?:v\d+)?\s*$',
        r'^(.+?)\s+-\s+Movies?\s*\d+\s*-\s*\d+',
        r'^(.+?)\s+(\d{1,4})-(\d{1,4})\s*[\[\(]',
        r'^(.+?)\s*-\s*(\d{1,4})(?:v\d+)?\s*[\[\(]',
        r'^(.+?)\s+-\s+\d{1,4}(?:v\d+)?\s+(?:\d{3,4}p|WEB|BD)',
        r'^(.+?)\s+-\s+\d{1,4}(?:v\d+)?\s+\((?:WEB|BD|DVD)',
        r'^(.+?)\s+-\s+E[Pp]?\d{1,4}',
        r'^(.+?)\s+\d{1,4}\s*-\s*\d{1,4}(?:\s+(?:English|Japanese|Subbed|Dubbed|Sub|Dub)|\s*$)',
        r'^(.+?\s*\(\d{4}\))\s*\(\d{1,4}\s*-\s*\d{1,4}\)',
        r'^(.+?)\s*\[\d{3,4}p\]\s*\(\d+',
        r'^(.+?)\s*\[\d{3,4}p\]\s*\[Complete',
        r'^(.+?)\s+HD\s*\[\d{3,4}p\]',
        r'^(.+?)\s+\d{1,4}-\d{1,4}\+',
        r'^(.+?)\s*\(\d{3,4}-\d{3,4}[^)]*\)',
        r'^(.+?)\s*\[(?:BD|BluRay|DVD|WEB)',
    ]

    for pattern in patterns:
        match = re.match(pattern, clean_name, re.IGNORECASE)
        if match:
            title = match.group(1).strip()
            title = re.sub(r'[\._]', ' ', title).strip()
            title = re.sub(r'\s+(?:REPACK|PROPER)$', '', title, flags=re.IGNORECASE)
            # Strip "Complete" suffix from batch releases
            title = re.sub(r'\s+Complete$', '', title, flags=re.IGNORECASE)
            title = strip_country_suffix(title)
            if len(title) >= 1 and re.search(r'[a-zA-Z0-9]', title):
                return title

    # Anime-style greedy patterns
    anime_patterns = [
        r'^(.+)\s+-\s+(\d{1,4})(?:v\d+)?\s*[\[\(]',
        r'^(.+)\s+-\s+(\d{1,4})(?:v\d+)?\s*$',
        r'^(.+)\s+-\s+(\d{1,4})(?:v\d+)?\s+\[',
        r'^(.+)\s+-\s+(\d{1,4})(?:v\d+)?\s+\(',
        r'^(.+)\s+-\s+(\d{1,4})(?:v\d+)?[\s\-]',
    ]

    for pattern in anime_patterns:
        anime_match = re.search(pattern, clean_name)
        if anime_match:
            title = anime_match.group(1).strip()
            ep_num = anime_match.group(2)
            if 1 <= int(ep_num) <= 9999:
                title = re.sub(r'[\._]', ' ', title).strip()
                title = re.sub(r'\s+(?:REPACK|PROPER)$', '', title, flags=re.IGNORECASE)
                title = re.sub(r'\s+Complete$', '', title, flags=re.IGNORECASE)
                title = strip_country_suffix(title)
                if len(title) >= 1 and re.search(r'[a-zA-Z0-9]', title):
                    return title

    # Last resort
    last_resort = re.match(r'^([A-Za-z][A-Za-z0-9\s\-]+?)\s+-\s+\d{1,4}', clean_name)
    if last_resort:
        title = last_resort.group(1).strip()
        title = re.sub(r'[\._]', ' ', title).strip()
        if len(title) >= 2 and re.search(r'[a-zA-Z]', title):
            return title

    # Fallback for batch/complete releases: "Title Complete Series (Season...)", "Title (001-220 + Movies)"
    batch_patterns = [
        # "Dragon Ball Super Complete Series (Season 01+02...)" -> "Dragon Ball Super"
        r'^(.+?)\s+(?:Complete\s+)?(?:Series|Collection)\s*\(',
        # "Naruto Complete (001-220 + Movies)" -> "Naruto"
        r'^(.+?)\s+Complete\s*\(',
        # "Pokemon Complete Series (Season" -> "Pokemon"
        r'^(.+?)\s+(?:Complete\s+)?(?:Series|Collection)$',
        # "Title (Season 01+02+03)" -> "Title"
        r'^(.+?)\s*\((?:Season|S)\s*\d',
        # "Title (001-220 + Movies)" -> "Title"
        r'^(.+?)\s*\(\d{1,4}\s*[-+]',
    ]
    for pattern in batch_patterns:
        match = re.match(pattern, clean_name, re.IGNORECASE)
        if match:
            title = match.group(1).strip()
            title = re.sub(r'[\._]', ' ', title).strip()
            # Strip "Complete", "Series", "Collection" from batch release titles
            title = re.sub(r'\s+(?:Complete\s+)?(?:Series|Collection)$', '', title, flags=re.IGNORECASE)
            title = re.sub(r'\s+Complete$', '', title, flags=re.IGNORECASE)
            title = strip_country_suffix(title)
            if len(title) >= 2 and re.search(r'[a-zA-Z]', title):
                return title

    # Final fallback: if clean_name is just a title (possibly with parenthetical alternate title)
    # after all preprocessing, extract the main title before any parenthesis
    fallback_match = re.match(r'^([A-Za-z][A-Za-z0-9\s\-\']+?)(?:\s*\([^)]+\))?(?:\s+(?:Season|S)\s*\d+)?$', clean_name, re.IGNORECASE)
    if fallback_match:
        title = fallback_match.group(1).strip()
        title = re.sub(r'[\._]', ' ', title).strip()
        title = re.sub(r'\s+(?:Complete\s+)?(?:Series|Collection)$', '', title, flags=re.IGNORECASE)
        title = strip_country_suffix(title)
        if len(title) >= 2 and re.search(r'[a-zA-Z]', title):
            return title

    return None


def extract_episode_info(folder_name: str) -> Optional[str]:
    """
    Extract episode information from folder name for series deduplication.
    Returns a string like "s01e01", "s01", "ep662", "batch-1-102", or None.
    """
    clean_name = strip_torrent_prefix(folder_name)

    # S01E01 format
    match = re.search(r'[Ss](\d{1,2})[Ee](\d{1,4})', clean_name)
    if match:
        return f"s{int(match.group(1)):02d}e{int(match.group(2)):03d}"

    # 1X01 format
    match = re.search(r'(\d{1,2})[Xx](\d{1,4})', clean_name)
    if match:
        return f"s{int(match.group(1)):02d}e{int(match.group(2)):03d}"

    # Anime with season in title: "One-Punch Man S3 - 01", "Title S2 - 13"
    # Must be before season-only to avoid S3 matching as season-only
    match = re.search(r'[Ss](\d{1,2})\s+-\s+(\d{1,4})', clean_name)
    if match:
        return f"s{int(match.group(1)):02d}e{int(match.group(2)):03d}"

    # (year) episode: "Pocket Monsters (2023) 090", "Title (2024) 12"
    match = re.search(r'\(\d{4}\)\s+(\d{1,4})(?:\s|\(|$)', clean_name)
    if match:
        return f"ep{int(match.group(1)):04d}"

    # Season only: "S01", "S3 ", "Season 2"
    match = re.search(r'[Ss](\d{1,2})(?:[\.\s\-_\+]|$)', clean_name)
    if match:
        return f"s{int(match.group(1)):02d}"
    # "Season 2", "Season.3" but NOT "Season - 03" where 03 is an episode
    match = re.search(r'Season[\.\s_]*(\d{1,2})(?!\s*-\s*\d)', clean_name, re.IGNORECASE)
    if match:
        return f"s{int(match.group(1)):02d}"

    # Episode range/batch: "(001-120)", "401~500"
    match = re.search(r'[\s\(](\d{1,4})\s*[-~]\s*(\d{1,4})(?:[\s\)]|$)', clean_name)
    if match:
        return f"batch-{match.group(1)}-{match.group(2)}"

    # Anime single episode: "- 01", "- E01", "Episode 01"
    match = re.search(r'\s+-\s+E?[Pp]?(\d{1,4})(?:v\d+)?(?:[\s\[\(\-]|$)', clean_name)
    if match:
        return f"ep{int(match.group(1)):04d}"
    match = re.search(r'Episode\s+(\d{1,4})', clean_name, re.IGNORECASE)
    if match:
        return f"ep{int(match.group(1)):04d}"

    return None


def get_group_key(folder_name: str, media_type: str = "movie") -> str:
    """
    Create grouping key for deduplication.
    """
    title, year = extract_title_year(folder_name)
    edition = extract_edition(folder_name)

    if media_type == "series" and not title:
        title = extract_series_title(folder_name)

    if not title:
        title = folder_name

    key = re.sub(r'[^\w\s]', '', title.lower())
    key = re.sub(r'\s+', '-', key.strip())

    if media_type == "movie" and year:
        key = f"{key}-{year}"

    if media_type == "series":
        ep_info = extract_episode_info(folder_name)
        if ep_info:
            key = f"{key}-{ep_info}"
        elif year:
            key = f"{key}-{year}"

    if edition:
        edition_key = edition.replace(' ', '-').replace("'", '')
        key = f"{key}--{edition_key}"

    return key


# =============================================================================
# TMDB/TVDB API Functions
# =============================================================================

def _get_tvdb_token() -> Optional[str]:
    """Get or refresh TVDB API token."""
    global _tvdb_token
    if not TVDB_API_KEY:
        return None

    with _tvdb_token_lock:
        if _tvdb_token:
            return _tvdb_token

        try:
            url = f"{TVDB_BASE_URL}/login"
            data = json.dumps({"apikey": TVDB_API_KEY}).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.loads(response.read().decode())
                _tvdb_token = result.get("data", {}).get("token")
                return _tvdb_token
        except (urllib.error.URLError, json.JSONDecodeError, KeyError, TimeoutError):
            return None


def _normalize_for_comparison(title: str) -> str:
    """Normalize title for comparison."""
    result = title.lower()
    result = result.replace('&', ' and ')
    result = re.sub(r'[^\w\s]', ' ', result)
    result = re.sub(r'^(the|a|an)\s+', '', result)
    result = re.sub(r'\s+', ' ', result).strip()
    return result


def _score_tmdb_result(query: str, result_title: str) -> int:
    """Score how well a TMDB result title matches the query."""
    query_norm = _normalize_for_comparison(query)
    result_norm = _normalize_for_comparison(result_title)

    if query_norm == result_norm:
        return 100

    query_words = set(query_norm.split())
    result_words = set(result_norm.split())

    if query_words and result_words:
        if query_words <= result_words:
            extra_words = len(result_words) - len(query_words)
            return 90 - min(extra_words * 5, 30)

        overlap = len(query_words & result_words)
        if overlap > 0:
            total = len(query_words | result_words)
            jaccard = overlap / total
            return int(jaccard * 60) + 10

    if result_norm in query_norm:
        length_diff = len(query_norm) - len(result_norm)
        return 75 - min(length_diff, 30)

    if query_norm in result_norm:
        length_diff = len(result_norm) - len(query_norm)
        return max(30 - length_diff * 3, 5)

    return 0


def _find_best_tmdb_result(results: List[dict], query: str, title_key: str, min_score: int = 40) -> Optional[dict]:
    """Find the best matching result from TMDB search results."""
    if not results:
        return None

    query_norm = _normalize_for_comparison(query)
    query_lower = query.lower().strip()

    scored_results = []
    for result in results[:10]:
        result_title = result.get(title_key, "")
        score = _score_tmdb_result(query, result_title)
        scored_results.append((score, result, result_title))

    scored_results.sort(key=lambda x: x[0], reverse=True)

    best_score, best_result, best_title = scored_results[0]
    best_title_norm = _normalize_for_comparison(best_title)
    best_title_lower = best_title.lower().strip()

    original_language = best_result.get("original_language", "")
    is_anime = original_language in ("ja", "jpn", "japanese")

    is_prefixed_match = (
        best_title_lower.endswith(query_lower) and
        len(best_title_lower) > len(query_lower)
    )

    if query_norm == best_title_norm:
        if best_score >= min_score:
            return best_result
    elif is_prefixed_match:
        if best_score >= 60:
            return best_result
    else:
        required_score = min_score if is_anime else 95
        if best_score >= required_score:
            return best_result

    return None


def tmdb_search_movie(title: str, year: Optional[str] = None) -> Optional[TMDBResult]:
    """Search TMDB for a movie and return full result."""
    if not TMDB_API_KEY:
        return None

    cache_key = f"movie:{title}:{year or ''}"
    with _tmdb_cache_lock:
        if cache_key in _tmdb_cache:
            return _tmdb_cache[cache_key]

    try:
        params = {"api_key": TMDB_API_KEY, "query": title}
        if year:
            params["year"] = year
        url = f"{TMDB_BASE_URL}/search/movie?{urllib.parse.urlencode(params)}"

        with urllib.request.urlopen(url, timeout=5) as response:
            data = json.loads(response.read().decode())
            if data.get("results"):
                result = _find_best_tmdb_result(data["results"], title, "title")
                if result:
                    release_date = result.get("release_date", "")
                    result_year = release_date[:4] if release_date else ""
                    tmdb_result = TMDBResult(
                        title=result.get("title", title),
                        year=result_year,
                        original_language=result.get("original_language", ""),
                        tmdb_id=result.get("id", 0)
                    )
                    with _tmdb_cache_lock:
                        _tmdb_cache[cache_key] = tmdb_result
                    return tmdb_result
    except (urllib.error.URLError, json.JSONDecodeError, KeyError, TimeoutError):
        pass

    with _tmdb_cache_lock:
        _tmdb_cache[cache_key] = None
    return None


def tmdb_search_tv(title: str, year: Optional[str] = None) -> Optional[TMDBResult]:
    """Search TMDB for a TV show and return full result."""
    if not TMDB_API_KEY:
        return None

    cache_key = f"tv:{title}:{year or ''}"
    with _tmdb_cache_lock:
        if cache_key in _tmdb_cache:
            return _tmdb_cache[cache_key]

    try:
        params = {"api_key": TMDB_API_KEY, "query": title}
        url = f"{TMDB_BASE_URL}/search/tv?{urllib.parse.urlencode(params)}"

        with urllib.request.urlopen(url, timeout=5) as response:
            data = json.loads(response.read().decode())
            if data.get("results"):
                result = _find_best_tmdb_result(data["results"], title, "name")
                if result:
                    first_air = result.get("first_air_date", "")
                    result_year = first_air[:4] if first_air else ""
                    tmdb_result = TMDBResult(
                        title=result.get("name", title),
                        year=result_year,
                        original_language=result.get("original_language", ""),
                        tmdb_id=result.get("id", 0)
                    )
                    with _tmdb_cache_lock:
                        _tmdb_cache[cache_key] = tmdb_result
                    return tmdb_result
    except (urllib.error.URLError, json.JSONDecodeError, KeyError, TimeoutError):
        pass

    with _tmdb_cache_lock:
        _tmdb_cache[cache_key] = None
    return None


def _fetch_tvdb_english_title(series_id: int, token: str) -> Optional[str]:
    """Fetch English title for a series from TVDB."""
    try:
        url = f"{TVDB_BASE_URL}/series/{series_id}/translations/eng"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {token}"}
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            return data.get("data", {}).get("name", "")
    except (urllib.error.URLError, json.JSONDecodeError, KeyError, TimeoutError):
        return None


def _find_best_tvdb_result(results: List[dict], query: str, min_score: int = 40) -> Optional[dict]:
    """Find the best matching result from TVDB search results."""
    if not results:
        return None

    query_norm = _normalize_for_comparison(query)
    query_lower = query.lower().strip()

    scored_results = []
    for result in results[:10]:
        translations = result.get("translations", {})
        english_title = translations.get("eng", "") if isinstance(translations, dict) else ""
        native_title = result.get("name", "")
        english_score = _score_tmdb_result(query, english_title) if english_title else 0
        native_score = _score_tmdb_result(query, native_title) if native_title else 0
        score = max(english_score, native_score)
        best_title = english_title if english_score >= native_score else native_title
        scored_results.append((score, result, best_title))

    scored_results.sort(key=lambda x: x[0], reverse=True)

    best_score, best_result, best_title = scored_results[0]
    best_title_norm = _normalize_for_comparison(best_title)
    best_title_lower = best_title.lower().strip()

    original_language = best_result.get("originalLanguage", "") or best_result.get("primary_language", "")
    is_anime = original_language in ("ja", "jpn", "japanese")

    is_prefixed_match = (
        best_title_lower.endswith(query_lower) and
        len(best_title_lower) > len(query_lower)
    )

    if query_norm == best_title_norm:
        if best_score >= min_score:
            return best_result
    elif is_prefixed_match:
        if best_score >= 60:
            return best_result
    else:
        required_score = min_score if is_anime else 95
        if best_score >= required_score:
            return best_result

    return None


def tvdb_search_tv(title: str, year: Optional[str] = None) -> Optional[TVDBResult]:
    """Search TVDB for a TV show and return full result."""
    token = _get_tvdb_token()
    if not token:
        return None

    cache_key = f"tvdb:{title}:{year or ''}"
    with _tvdb_cache_lock:
        if cache_key in _tvdb_cache:
            return _tvdb_cache[cache_key]

    try:
        params = {"query": title, "type": "series"}
        url = f"{TVDB_BASE_URL}/search?{urllib.parse.urlencode(params)}"

        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {token}"}
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            results = data.get("data", [])
            if results:
                result = _find_best_tvdb_result(results, title)
                if result:
                    result_year = result.get("year", "")
                    if not result_year:
                        first_air = result.get("first_air_time", "") or result.get("firstAired", "")
                        result_year = first_air[:4] if first_air else ""

                    translations = result.get("translations", {})
                    english_title = translations.get("eng", "") if isinstance(translations, dict) else ""
                    native_title = result.get("name", "")

                    if not english_title:
                        series_id = result.get("tvdb_id") or result.get("id")
                        name_translations = result.get("nameTranslations", [])
                        if series_id and "eng" in name_translations:
                            english_title = _fetch_tvdb_english_title(series_id, token)

                    display_title = english_title or native_title or title
                    tvdb_result = TVDBResult(
                        title=display_title,
                        year=str(result_year) if result_year else "",
                        original_language=result.get("originalLanguage", "") or result.get("primary_language", ""),
                        tvdb_id=int(result.get("tvdb_id", 0) or result.get("id", 0))
                    )
                    with _tvdb_cache_lock:
                        _tvdb_cache[cache_key] = tvdb_result
                    return tvdb_result
    except (urllib.error.URLError, json.JSONDecodeError, KeyError, TimeoutError):
        pass

    with _tvdb_cache_lock:
        _tvdb_cache[cache_key] = None
    return None


def _convert_tvdb_to_tmdb_result(tvdb_result: TVDBResult) -> TMDBResult:
    """Convert TVDBResult to TMDBResult for compatibility."""
    return TMDBResult(
        title=tvdb_result.title,
        year=tvdb_result.year,
        original_language=tvdb_result.original_language,
        tmdb_id=0
    )


def _search_tv_with_fallback(title: str, year: Optional[str] = None) -> Optional[TMDBResult]:
    """Search for TV series using TVDB with TMDB fallback."""
    if TVDB_API_KEY:
        tvdb_result = tvdb_search_tv(title, year)
        if tvdb_result:
            return _convert_tvdb_to_tmdb_result(tvdb_result)

    if TMDB_API_KEY:
        return tmdb_search_tv(title, year)

    return None


def get_original_language(title: str, year: Optional[str], media_type: str) -> Optional[str]:
    """Get original language for a title from TMDB."""
    if media_type == "movie":
        result = tmdb_search_movie(title, year)
    else:
        result = tmdb_search_tv(title, year)

    return result.original_language if result else None


# =============================================================================
# Content Filtering Functions
# =============================================================================

def is_ai_upscale(folder_name: str) -> bool:
    """Check if folder name indicates AI upscaled content."""
    return bool(AI_UPSCALE_REGEX.search(folder_name))


def is_torrent_hash(folder_name: str) -> bool:
    """Check if folder name is a torrent hash/ID."""
    return bool(re.match(r'^[0-9a-fA-F]{32}(?:\[|$)', folder_name))


def is_trash_release(name: str) -> bool:
    """Check if release is trash-tier quality.

    Rejects known low-quality release groups (per TRaSH Guides) across movies,
    series, and anime, plus bare WEBRips.
    """
    # Known trash release groups — universally bad regardless of media type.
    #
    # Movies/general:
    #   YTS, YIFY, aXXo           — micro-encodes / ancient re-encodes
    #   MkvCage, EVO, FGT, x0r    — poor re-encodes
    #   PSA, GalaxyRG, ION10      — low bitrate re-encodes
    #   BONE                      — watermarked releases
    #   SPARKS, PROFiLE, AFG      — per TRaSH Guides unwanted
    #   STUTTERSHIT, CrEwSaDe     — self-explanatory / bad re-encodes
    #   NOMA, NAHOM, TiTAN, WAF   — bad quality
    #   SiNNERS, Morpheus, BONSAI — bad quality
    #   KING, d3g, iPlanet        — bad quality
    #   HDTime, RDN, AJP69, HEART — bad quality
    #
    # Series-specific:
    #   EZTV          — re-encodes, mislabeled quality
    #   MeGusta, JOY  — re-encodes
    #   CAKES, HANDJOB — bad quality
    #
    # Anime-specific:
    #   Judas, Cleo, Bonkai77     — low bitrate re-encodes
    #   neoHEVC                   — micro-encodes
    #
    # Dual-audio / foreign:
    #   TURG                      — Turkish EN-TR/DUAL WEB-DL; near-zero usenet
    #                               availability, never completes → re-grab loop
    #
    trash_groups = {
        'axxo', 'yts', 'yify',
        'mkvcage', 'evo', 'fgt', 'x0r',
        'psa', 'psarips', 'galaxyrg', 'ion10', 'bone',
        'sparks', 'profile', 'afg',
        'stuttershit', 'crewsade',
        'noma', 'nahom', 'titan', 'waf',
        'sinners', 'morpheus', 'bonsai',
        'king', 'd3g', 'iplanet', 'hdtime', 'rdn', 'ajp69', 'heart',
        'eztv', 'megusta', 'joy', 'cakes', 'handjob',
        'judas', 'cleo', 'bonkai77', 'neohevc',
        'turg',
    }
    # Extract release group from the filename:
    #   Standard: "Title.1080p.WEB-DL-GROUP.mkv" or "Title-GROUP[hash].mkv"
    #   Anime:    "[Group] Title - 01.mkv"
    basename = re.sub(r'\.\w{2,4}$', '', name)  # strip file extension
    basename = re.sub(r'-(?:Obfuscated|OBFUSCATED|obfuscated|Scrambled|AsRequested|Rakuv\d*)$', '', basename)  # strip common Usenet tags
    group_match = re.search(r'-([A-Za-z0-9]+)(?:\[.*\])?$', basename)
    if group_match and group_match.group(1).lower() in trash_groups:
        return True
    # Bracketed / dotted-suffix release-group form at end of name:
    #   ...-[YTS.BZ], ...-[YTS.MX], ...-[YIFY]   (modern YTS clone naming)
    #   ...-YTS.MX, ...-YTS.LT                   (unbracketed but dotted)
    # The primary regex above can't see these because the alnum+ chain breaks
    # on the leading `[` or the embedded `.`.
    bracket_match = re.search(r'-\[?([A-Za-z0-9]+)(?:\.[A-Za-z]{2,4})?\]?$', basename)
    if bracket_match and bracket_match.group(1).lower() in trash_groups:
        return True
    anime_match = re.match(r'^\[([^\]]+)\]', name)
    if anime_match and anime_match.group(1).lower() in trash_groups:
        return True
    # WEBRip below 1080p without BluRay/REMUX — inferior to WEB-DL
    if re.search(r'[\.\s\-_](WEBRip|WEB[\.\-\s]?Rip)[\.\s\-_]', name, re.IGNORECASE):
        if not re.search(r'(REMUX|BluRay|Blu[\.\-\s]?Ray)', name, re.IGNORECASE):
            if not re.search(r'(1080p|2160p|4K|UHD)', name, re.IGNORECASE):
                return True
    return False


def has_english_audio(folder_name: str) -> bool:
    """Check if folder name indicates English audio is included."""
    return bool(re.search(r'[\.\s\-_](ENG|ENGLISH)[\.\s\-_]', folder_name, re.IGNORECASE))


def extract_language_tag(folder_name: str) -> Optional[str]:
    """Extract language tag from folder name if present."""
    if has_english_audio(folder_name):
        return None

    quality_pattern = r'(2160p|1080p|720p|480p|4K|UHD|BluRay|Blu-Ray|WEB-DL|WEBRip|HDTV|REMUX)'
    quality_match = re.search(quality_pattern, folder_name, re.IGNORECASE)

    if quality_match:
        search_portion = folder_name[quality_match.start():]
    else:
        search_portion = folder_name

    pattern = r'[\.\s\-_\[\(](FRENCH|GERMAN|ITALIAN|SPANISH|JAPANESE|KOREAN|CHINESE|RUSSIAN|PORTUGUESE|DUTCH|SWEDISH|NORWEGIAN|DANISH|FINNISH|POLISH|TURKISH|ARABIC|HINDI|THAI)[\.\s\-_\]\)]'
    match = re.search(pattern, search_portion, re.IGNORECASE)
    if match:
        lang = match.group(1).lower()
        if lang == "japanese":
            full_match = re.search(r'\bJAPANESE[\.\s\-_](\w+)', folder_name, re.IGNORECASE)
            if full_match:
                next_word = full_match.group(1).lower()
                title_words = {'toilet', 'garden', 'house', 'food', 'style', 'culture', 'art', 'story', 'movie', 'film'}
                if next_word in title_words:
                    return None
        return lang
    return None


def is_english_content(folder_name: str) -> Tuple[bool, str]:
    """
    Check if folder name appears to be English content (basic check).
    Returns (is_english, reason_if_not).
    """
    if is_torrent_hash(folder_name):
        return False, "torrent hash ID"

    if is_ai_upscale(folder_name):
        return False, "AI upscale"

    if re.search(r'[\.\s\-_](BRRip|BR-Rip|BDRip|BD-Rip|DVDRip|DVD-Rip|DvDRip)[\.\s\-_]', folder_name, re.IGNORECASE):
        return False, "low-quality rip (BRRip/BDRip/DVDRip)"

    if is_trash_release(folder_name):
        return False, "low-quality release group"

    foreign_dub_pattern = re.search(
        r'[\.\s\-_](Ger(?:man)?|Ita(?:lian)?|Fra(?:nce)?|French|Spa(?:nish)?|Dut(?:ch)?|'
        r'Rus(?:sian)?|Jpn|Kor(?:ean)?)[\.\s\-_].*Dubbed|'
        r'Dubbed[\.\s\-_].*(Ger(?:man)?|Ita(?:lian)?|Fra(?:nce)?|French|Spa(?:nish)?|'
        r'Dut(?:ch)?|Rus(?:sian)?|Jpn|Kor(?:ean)?)',
        folder_name, re.IGNORECASE
    )
    if foreign_dub_pattern:
        matched = foreign_dub_pattern.group(0).strip('.-_ ')
        return False, f"foreign dub: '{matched}'"

    has_ita_marker = bool(re.search(r'[^\w](ita)[^\w]', folder_name, re.IGNORECASE))
    title_match = re.match(r'^(.+?)[\.\s\-_]*(19|20)\d{2}', folder_name)
    title_portion = title_match.group(1) if title_match else folder_name.split('.')[0]

    if has_ita_marker:
        italian_patterns = re.search(
            r'\b(il|la|lo|gli|le|del|della|dell|dello|nel|nell|nella|nello|'
            r'sul|sulla|sullo|al|alla|allo|dal|dalla|di|da|per|tra|fra|'
            r'vita|ritorno|grande|caccia|benvenuti|animali|incubo|'
            r'trappola|pistoleri|sai|tenere|segreto|tutto|quello|che|non|ho|detto|ti|'
            r'accetta|rifiuta|storia|sogno|impossibile|'
            r'mio|amico|pinguino|fedele|cosa|hai|fatto|tutti|diavoli|sono|qui|'
            r'battaglia|dopo|altra|fantasma|lupi|solitari|eterna|suburraeterna)\b',
            title_portion, re.IGNORECASE
        )
        if italian_patterns:
            return False, f"Italian-titled: '{italian_patterns.group(0)}' with .ITA. marker"
    else:
        # Without ITA marker: look for Italian multi-word phrases (more conservative)
        italian_phrase = re.search(
            r'[\.\s\-_](La|Il|Lo|Gli|Le|Un|Una)[\.\s\-_](Grande|Piccol[ao]|Bell[ao]|'
            r'Brut[ao]|Nuov[ao]|Vecchi[ao]|Ultim[ao]|Prim[ao]|'
            r'Storia|Sogno|Trappola|Caccia|Battaglia|'
            r'Viaggio|Straordinari[ao]|Segret[ao]|Amore|Giorno|Notte|Mondo|Tempo|'
            r'Amico|Pinguino|Fedele|Fantasma|Diavoli)\b|'
            r'[\.\s\-_](Vita|Ritorno|Benvenuti|Caccia|Incubo|Trappola|Viaggio)[\.\s\-_](da|al|del|nell|di|in|verso)\b|'
            r'[\.\s\-_](del|della|nell|nella|dal|dalla)[\.\s\-_]|'
            r'(?:^|[\.\s\-_])(Tutti|Cosa|Dopo|So|Lupi)[\.\s\-_](I|Hai|L|La|Solitari)\b|'
            r'\b(Suburraeterna)\b',
            title_portion, re.IGNORECASE
        )
        if italian_phrase:
            return False, f"Italian-titled: '{italian_phrase.group(0).strip('.-_ ')}'"

    # Detect Russian romanized titles
    russian_words = re.search(
        r'\b(posle|navsegda|vsegda|kogda|nikogda|segodnya|zavtra|'
        r'tolko|lyubov|smert|noch|den|zhizn|mir|voyna|dom|gorod)\b',
        title_portion, re.IGNORECASE
    )
    if russian_words:
        return False, f"Russian-titled: contains '{russian_words.group(0)}'"

    # Detect Spanish-titled releases (multi-word phrases)
    spanish_phrase = re.search(
        r'[\.\s\-_](Un|Una|El|La|Los|Las)[\.\s\-_](Fantasma|Batalla|Guerra|Amor|Vida|'
        r'Dia|Noche|Hombre|Mujer|Rey|Reina|Mundo|Tiempo|Casa|Ciudad)\b',
        title_portion, re.IGNORECASE
    )
    if spanish_phrase:
        return False, f"Spanish-titled: '{spanish_phrase.group(0).strip('.-_ ')}'"

    if re.search(r'[\.\s\-_](CZ|SK)[\.\s\-_]', folder_name):
        return False, "Czech/Slovak release (.CZ./.SK. marker)"

    if re.search(r'[\.\s\-_\(\[\{](CZ[_\.]EN|EN[_\.]CZ)[\.\s\-_\)\]\}]', folder_name, re.IGNORECASE):
        return False, "Czech/English dual release (CZ_EN)"

    if re.search(r'[\.\s\-_](UKR)[\.\s\-_]', folder_name, re.IGNORECASE):
        return False, "Ukrainian release (.UKR. marker)"

    # Detect Czech-titled releases by common Czech words in title portion
    czech_words = re.search(
        r'\b(dni|dlouha|dlouhy|noc|hodina|zmizeni|prvni|posledni|velky|velka|'
        r'maly|mala|novy|nova|stary|stara|cerveny|cervena|modry|modra|'
        r'zlaty|zlata|tajny|tajna|ztraceny|ztracena|navrat|cesta|zivot)\b',
        title_portion, re.IGNORECASE
    )
    if czech_words:
        return False, f"Czech-titled: contains '{czech_words.group(0)}'"

    # Detect romanized Japanese light novel/anime titles (3+ particles = filter)
    japanese_particles = re.findall(
        r'[\.\s\-_](no|ga|wa|wo|mo|ni|de|to|yori|nara|kara|made|dake|shika|demo|'
        r'aru|nai|desu|masu|ore|boku|watashi|kimi|omae|san|kun|chan|sama|sensei)[\.\s\-_]',
        folder_name, re.IGNORECASE
    )
    if len(japanese_particles) >= 3:
        return False, f"romanized Japanese title ({len(japanese_particles)} particles)"

    # Detect Central/Eastern European diacritics in title
    cee_diacritics = re.search(
        r'[ěščřžýáíéúůďťňľĺŕôäëïöüàèìòùâêîôûćźńśłęą]',
        folder_name, re.IGNORECASE
    )
    if cee_diacritics:
        return False, f"Central European title: contains '{cee_diacritics.group(0)}'"

    non_latin_patterns = [
        r'[\u0400-\u04FF]',
        r'[\u4E00-\u9FFF]',
        r'[\uAC00-\uD7AF]',
        r'[\u0600-\u06FF]',
        r'[\u0590-\u05FF]',
        r'[\u0E00-\u0E7F]',
        r'[\u0900-\u097F]',
    ]
    non_latin_regex = re.compile('|'.join(non_latin_patterns))

    match = non_latin_regex.search(folder_name)
    if match:
        matched_text = match.group(0)
        return False, f"non-Latin script: '{matched_text}'"

    # FIX 3: Detect known non-English release groups/markers
    # Note: Greek (GrLTv) is intentionally NOT filtered - Greek series are monitored
    non_english_indicators = [
        # Russian
        ('ELEKTRI4KA', 'russian release group'),
        ('UNIONGANG', 'russian release group'),
        # Polish
        ('POLSKIE-TORRENTY', 'polish release group'),
        ('[electro-torrent.pl]', 'polish release group'),
    ]

    for indicator, reason in non_english_indicators:
        if indicator in folder_name:
            return False, reason

    return True, ""


def is_english_content_smart(
    folder_name: str,
    title: Optional[str],
    year: Optional[str],
    media_type: str
) -> Tuple[bool, str]:
    """Smart language check using TMDB API."""
    english, reason = is_english_content(folder_name)
    if not english:
        return False, reason

    lang_tag = extract_language_tag(folder_name)
    if not lang_tag:
        return True, ""

    if re.search(r'\b(VOSTFR|TRUEFRENCH)\b', folder_name, re.IGNORECASE):
        lang_tag = "french"

    if not TMDB_API_KEY:
        if lang_tag in ("french", "italian"):
            return False, f"non-English: '{lang_tag.upper()}' (no TMDB API)"
        return True, ""

    if title:
        original_lang = get_original_language(title, year, media_type)

        if original_lang:
            tag_code = LANGUAGE_TAG_TO_CODE.get(lang_tag)

            if tag_code and tag_code == original_lang:
                return True, ""

            if original_lang == "en" and tag_code:
                return False, f"dub: '{lang_tag.upper()}' (original: English)"

            if original_lang != "en" and tag_code and tag_code != original_lang:
                return False, f"dub: '{lang_tag.upper()}' (original: {original_lang})"

    if lang_tag in ("french", "italian"):
        return False, f"non-English: '{lang_tag.upper()}'"

    return True, ""


# =============================================================================
# Audio-track language check (ffprobe-based, file-level)
# =============================================================================
#
# Catches releases whose release-name passes the title-based filters but whose
# actual first audio track is foreign (LATAM remuxes, RUS BD dubs, Turkish NF
# DUAL grabs, etc.). Release-name CFs and is_english_content() cannot see
# inside the file; this function ffprobes the imported file directly.

# ISO 639-2/B is what most MKV mux tools write into stream tag:language.
# Map every common alias (TMDB names, ISO 639-1, ISO 639-2/B and 2/T variants,
# and Radarr/Sonarr `originalLanguage.name` strings) onto a canonical 3-letter code.
LANG_ALIAS_TO_ISO639_2 = {
    # English
    "eng": "eng", "en": "eng", "english": "eng",
    # Spanish (and Latin American Spanish dub aliases)
    "spa": "spa", "es": "spa", "spanish": "spa", "esp": "spa",
    "lat": "spa", "latino": "spa", "latin": "spa", "castellano": "spa",
    # French
    "fre": "fre", "fra": "fre", "fr": "fre", "french": "fre",
    # German
    "ger": "ger", "deu": "ger", "de": "ger", "german": "ger",
    # Italian
    "ita": "ita", "it": "ita", "italian": "ita",
    # Portuguese (incl. Brazilian)
    "por": "por", "pt": "por", "portuguese": "por", "brasileno": "por",
    "brazilian": "por", "brasileiro": "por",
    # Russian
    "rus": "rus", "ru": "rus", "russian": "rus",
    # Japanese
    "jpn": "jpn", "ja": "jpn", "japanese": "jpn",
    # Korean
    "kor": "kor", "ko": "kor", "korean": "kor",
    # Chinese / Mandarin / Cantonese
    "chi": "chi", "zho": "chi", "zh": "chi", "chinese": "chi",
    "mandarin": "chi", "cantonese": "chi",
    # Dutch
    "dut": "dut", "nld": "dut", "nl": "dut", "dutch": "dut",
    # Nordic
    "swe": "swe", "sv": "swe", "swedish": "swe",
    "dan": "dan", "da": "dan", "danish": "dan",
    "nor": "nor", "no": "nor", "nob": "nor", "norwegian": "nor",
    "fin": "fin", "fi": "fin", "finnish": "fin",
    "isl": "isl", "is": "isl", "ice": "isl", "icelandic": "isl",
    # Eastern European
    "pol": "pol", "pl": "pol", "polish": "pol",
    "ukr": "ukr", "uk": "ukr", "ukrainian": "ukr",
    "cze": "cze", "ces": "cze", "cs": "cze", "czech": "cze",
    "slo": "slo", "slk": "slo", "sk": "slo", "slovak": "slo",
    "hun": "hun", "hu": "hun", "hungarian": "hun",
    "rum": "rum", "ron": "rum", "ro": "rum", "romanian": "rum",
    "bul": "bul", "bg": "bul", "bulgarian": "bul",
    "gre": "gre", "ell": "gre", "el": "gre", "greek": "gre",
    # Middle Eastern / South Asian
    "tur": "tur", "tr": "tur", "turkish": "tur",
    "ara": "ara", "ar": "ara", "arabic": "ara",
    "heb": "heb", "he": "heb", "hebrew": "heb",
    "fas": "fas", "per": "fas", "fa": "fas", "persian": "fas", "farsi": "fas",
    "hin": "hin", "hi": "hin", "hindi": "hin",
    "tam": "tam", "ta": "tam", "tamil": "tam",
    "tel": "tel", "te": "tel", "telugu": "tel",
    "ben": "ben", "bn": "ben", "bengali": "ben",
    "urd": "urd", "ur": "urd", "urdu": "urd",
    "mal": "mal", "ml": "mal", "malayalam": "mal",
    # Southeast Asian
    "tha": "tha", "th": "tha", "thai": "tha",
    "vie": "vie", "vi": "vie", "vietnamese": "vie",
    "ind": "ind", "id": "ind", "indonesian": "ind",
    "may": "may", "msa": "may", "ms": "may", "malay": "may",
    "fil": "fil", "tl": "fil", "tgl": "fil", "tagalog": "fil", "filipino": "fil",
    # South Asian (additional)
    "guj": "guj", "gu": "guj", "gujarati": "guj",
    "kan": "kan", "kn": "kan", "kannada": "kan",
    "pan": "pan", "pa": "pan", "punjabi": "pan",
    "mar": "mar", "mr": "mar", "marathi": "mar",
    "nep": "nep", "ne": "nep", "nepali": "nep",
    "sin": "sin", "si": "sin", "sinhala": "sin",
    # Celtic / less common European
    "wel": "wel", "cym": "wel", "cy": "wel", "welsh": "wel",
    "gle": "gle", "ga": "gle", "irish": "gle", "gaelic": "gle",
    "slv": "slv", "sl": "slv", "slovenian": "slv",
    "srp": "srp", "sr": "srp", "serbian": "srp",
    "hrv": "hrv", "hr": "hrv", "croatian": "hrv",
    "lit": "lit", "lt": "lit", "lithuanian": "lit",
    "lav": "lav", "lv": "lav", "latvian": "lav",
    "est": "est", "et": "est", "estonian": "est",
    # African
    "swa": "swa", "sw": "swa", "swahili": "swa",
    "amh": "amh", "am": "amh", "amharic": "amh",
    "afr": "afr", "af": "afr", "afrikaans": "afr",
    "zul": "zul", "zu": "zul", "zulu": "zul",
}

# Audio language tags that mean "untagged / unknown / not applicable" — never reject these.
# zxx = "no linguistic content" (music, noise). mis = "uncoded". qaa = "reserved local use".
UNDETERMINED_LANG_CODES = {"", "und", "unknown", "mis", "zxx", "qaa", "mul"}


def normalize_lang_code(value: Optional[str]) -> Optional[str]:
    """Normalize a language hint into the canonical ISO 639-2/B 3-letter code.

    Accepts ISO 639-1 (`en`, `es`), ISO 639-2 B/T (`eng`, `spa`, `fre`/`fra`),
    full names from TMDB / arr `originalLanguage.name` (`English`, `Spanish`),
    and some common in-stream variants (`Latino`, `Brasileno`). Returns None
    for inputs the alias table doesn't recognise.
    """
    if not value:
        return None
    key = value.strip().lower()
    # Strip common decorators that show up in stream titles ("Latino", "Inglés", etc.)
    key = re.sub(r'[áàâä]', 'a', key)
    key = re.sub(r'[éèêë]', 'e', key)
    key = re.sub(r'[íìîï]', 'i', key)
    key = re.sub(r'[óòôö]', 'o', key)
    key = re.sub(r'[úùûü]', 'u', key)
    key = re.sub(r'[ñ]', 'n', key)
    return LANG_ALIAS_TO_ISO639_2.get(key)


def probe_first_audio_language(filepath: str, timeout: int = 15) -> Optional[str]:
    """Return the ISO 639-2/B code of the first audio track in `filepath`.

    Returns None if ffprobe is missing, times out, the file cannot be read, or
    the audio is untagged / `und`. Callers should treat None as "skip" rather
    than "reject" — refusing to delete on tool failure is the right default
    when the alternative is mass-deleting on a transient FUSE hiccup.

    Hang-resistant: ffprobe is spawned via Popen in its own process group; on
    timeout we SIGKILL the whole group and **return immediately** rather than
    waiting on it. This is critical because zurg/rclone FUSE mounts can wedge
    on RD-link errors and leave ffprobe stuck in D-state (uninterruptible
    kernel sleep) for hours. subprocess.run(timeout=...) would block in
    Popen.wait() trying to reap the kill, deadlocking the worker pool.
    """
    import os
    import signal
    import subprocess
    try:
        proc = subprocess.Popen(
            [
                "ffprobe", "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream_tags=language",
                "-of", "default=nokey=1:noprint_wrappers=1",
                filepath,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # gives the child its own pgid so we can killpg
        )
    except (FileNotFoundError, OSError):
        return None
    try:
        stdout, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Send SIGKILL to the whole process group. The D-state child may not
        # actually die until FUSE returns, but we DO NOT wait — just abandon.
        # It will reparent to init and reap itself eventually.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        return None
    except (OSError, ValueError):
        return None
    if proc.returncode != 0:
        return None
    raw = stdout.decode("utf-8", errors="replace").strip().split('\n')[0].strip().lower().rstrip(',').strip()
    if raw in UNDETERMINED_LANG_CODES:
        return None
    return normalize_lang_code(raw) or raw


def check_audio_language(
    filepath: str,
    expected_lang: str = "eng",
    timeout: int = 15,
) -> Tuple[bool, str]:
    """Verify the file's first audio track matches `expected_lang`.

    `expected_lang` accepts any form `normalize_lang_code` understands.
    Returns (True, "") on match or when the probe cannot determine the
    language (defensive: never reject on tool failure). Returns
    (False, "<reason>") when there is a confirmed mismatch.
    """
    expected_iso = normalize_lang_code(expected_lang) or "eng"
    actual_iso = probe_first_audio_language(filepath, timeout=timeout)
    if actual_iso is None:
        return True, ""
    if actual_iso == expected_iso:
        return True, ""
    return False, f"first audio is '{actual_iso}' (expected '{expected_iso}')"


def is_valid_anime_name(folder_name: str) -> Tuple[bool, str]:
    """Check if folder name is valid for anime (series, not movies).

    Filters out movie patterns (year + no series markers) to prevent
    anime movies from passing through as series content.
    """
    clean_name = re.sub(r'^\[[^\]]+\]\s*', '', folder_name)

    alpha_content = re.sub(r'[^a-zA-Z0-9]', '', clean_name)
    if len(alpha_content) < 3:
        return False, "insufficient content"

    if re.match(r'^[\d\s\-\.pPkK]+$', clean_name):
        return False, "no title content"

    # Check for series markers to distinguish anime series from movies
    # If has year pattern (like a movie) but NO episode/season markers, filter it
    # FIX 1: Year regex now includes ) and ] after year to catch "Your Name (2016)"
    has_year = bool(re.search(r'(?:19|20)\d{2}(?:[\s\.\-\)\]\}]|$)', clean_name))

    # FIX 2: Detect movie keywords in folder name
    has_movie_keyword = bool(re.search(r'\bMovie\b', clean_name, re.IGNORECASE))

    has_series_markers = bool(
        re.search(r'[Ss]\d{1,2}[Ee]\d{1,4}', clean_name) or  # S01E01
        re.search(r'\d{1,2}[Xx]\d{1,4}', clean_name) or      # 1x01
        re.search(r'Season\s*\d+', clean_name, re.I) or       # Season 1
        re.search(r'[Ss]\d{1,2}(?:[\.\s\-_\+]|$)', clean_name) or  # S01
        re.search(r'\s+-\s+E?[Pp]?\d{1,4}(?:v\d+)?(?:[\s\[\(\-]|$)', clean_name) or  # - 01, - E01
        re.search(r'Episode\s+\d+', clean_name, re.I) or      # Episode 1
        re.search(r'[\s\(]\d{1,4}\s*-\s*\d{1,4}(?:[\s\)]|$)', clean_name) or  # batch (001-220)
        re.search(r'Complete\s+(?:Series|Collection)', clean_name, re.I) or  # Complete Series
        re.search(r'\((?:Anime|OVA|Special)', clean_name, re.I)  # (Anime), (OVA)
    )

    # FIX 2: Filter items with movie keyword (anime folder shouldn't have movies)
    if has_movie_keyword:
        return False, "movie keyword in anime folder"

    if has_year and not has_series_markers:
        return False, "movie pattern (no series markers)"

    return True, ""


def is_valid_media_name(folder_name: str, is_series: bool = False) -> Tuple[bool, str]:
    """Check if folder name follows proper media naming (basic check)."""
    title, year = extract_title_year(folder_name)

    if not title and is_series:
        series_title = extract_series_title(folder_name)
        if series_title:
            return True, ""

    if not title:
        return False, "no title detected"

    if not year:
        return False, "no year detected"

    try:
        year_int = int(year)
        if year_int < 1900 or year_int > 2030:
            return False, f"invalid year {year}"
    except ValueError:
        return False, "invalid year format"

    if len(title) < 2:
        return False, "title too short"

    return True, ""


def tmdb_validate_title(
    folder_name: str,
    extracted_title: Optional[str],
    extracted_year: Optional[str],
    media_type: str
) -> Optional[TMDBResult]:
    """
    Validate and potentially correct title/year extraction using TMDB/TVDB.
    Returns TMDBResult if found, None otherwise.
    """
    if not TMDB_API_KEY and not TVDB_API_KEY:
        return None

    if media_type == "movie":
        search_func = tmdb_search_movie
    else:
        search_func = _search_tv_with_fallback

    clean_folder = strip_torrent_prefix(folder_name)

    # Strategy 1: Try with extracted title and year
    if extracted_title:
        cleaned_title = clean_title_for_search(extracted_title)

        result = search_func(cleaned_title, extracted_year)
        if result:
            return result

        result = search_func(cleaned_title, None)
        if result:
            return result

        if cleaned_title != extracted_title:
            result = search_func(extracted_title, extracted_year)
            if result:
                return result
            result = search_func(extracted_title, None)
            if result:
                return result

        stripped_episode = strip_episode_from_title(extracted_title)
        if stripped_episode != extracted_title and len(stripped_episode) >= 2:
            result = search_func(stripped_episode, extracted_year)
            if result:
                return result
            result = search_func(stripped_episode, None)
            if result:
                return result

        stripped_edition = strip_edition_from_title(extracted_title)
        if stripped_edition != extracted_title:
            result = search_func(stripped_edition, extracted_year)
            if result:
                return result
            result = search_func(stripped_edition, None)
            if result:
                return result

        stripped_title = strip_country_suffix(extracted_title)
        if stripped_title != extracted_title:
            result = search_func(stripped_title, extracted_year)
            if result:
                return result
            result = search_func(stripped_title, None)
            if result:
                return result

        stripped_brackets = strip_brackets_from_title(extracted_title)
        if stripped_brackets != extracted_title:
            result = search_func(stripped_brackets, extracted_year)
            if result:
                return result
            result = search_func(stripped_brackets, None)
            if result:
                return result

        if re.search(r'\s+(?:aka|AKA)\s+', extracted_title):
            parts = re.split(r'\s+(?:aka|AKA)\s+', extracted_title)
            for part in parts:
                part = part.strip()
                if part and len(part) >= 2:
                    result = search_func(part, extracted_year)
                    if result:
                        return result
                    result = search_func(part, None)
                    if result:
                        return result

    if media_type == "series":
        series_title = extract_series_title(folder_name)
        if series_title and series_title != extracted_title:
            result = search_func(series_title, extracted_year)
            if result:
                return result
            result = search_func(series_title, None)
            if result:
                return result

    aka_titles = extract_aka_titles(clean_folder)
    for aka_title in aka_titles:
        result = search_func(aka_title, extracted_year)
        if result:
            return result
        result = search_func(aka_title, None)
        if result:
            return result

    title_no_year = extract_title_without_year(folder_name)
    if title_no_year and title_no_year != extracted_title:
        result = search_func(title_no_year, None)
        if result:
            return result

    return None


def is_valid_media_name_smart(
    folder_name: str,
    is_series: bool = False
) -> Tuple[bool, str, Optional[TMDBResult]]:
    """
    Smart media name validation using TMDB.
    Returns (is_valid, reason_if_invalid, tmdb_result).
    """
    media_type = "series" if is_series else "movie"

    english, reason = is_english_content(folder_name)
    if not english:
        return False, reason, None

    clean_folder = strip_torrent_prefix(folder_name)
    title, year = extract_title_year(clean_folder)

    if is_series and title:
        title = strip_episode_from_title(title)
        title = re.sub(r'\s+[A-Z][a-z]+\s+\d{1,2}\s*$', '', title)
        title = title.strip()

    if not title and is_series:
        title = extract_series_title(clean_folder)
        year = None

    if not title and not is_series:
        title = extract_title_without_year(clean_folder)
        year = None

    if TMDB_API_KEY:
        tmdb_result = tmdb_validate_title(folder_name, title, year, media_type)

        if tmdb_result:
            return True, "", tmdb_result

        if title:
            return True, "", None
        else:
            return False, "no title detected", None

    if not title:
        return False, "no title detected", None

    if not year and not is_series:
        return False, "no year detected", None

    if year:
        try:
            year_int = int(year)
            if year_int < 1900 or year_int > 2030:
                return False, f"invalid year {year}", None
        except ValueError:
            return False, "invalid year format", None

    if len(title) < 2:
        return False, "title too short", None

    return True, "", None


# =============================================================================
# *arr API Client
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

    def _request(self, endpoint: str, method: str = "GET", data: Optional[dict] = None) -> dict:
        full_url = f"{self.url}{self.base_url}/api/v3{endpoint}"
        req = urllib.request.Request(full_url, method=method)
        req.add_header("X-Api-Key", self.api_key)
        req.add_header("Content-Type", "application/json")

        if data:
            req.data = json.dumps(data).encode("utf-8")

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            log_error(f"API error: {e.code} {e.reason} - {full_url}")
            raise
        except urllib.error.URLError as e:
            log_error(f"Connection error: {e.reason} - {full_url}")
            raise

    def _delete(self, endpoint: str) -> bool:
        """Send DELETE request."""
        full_url = f"{self.url}{self.base_url}/api/v3{endpoint}"
        req = urllib.request.Request(full_url, method="DELETE")
        req.add_header("X-Api-Key", self.api_key)

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status == 200 or resp.status == 204
        except urllib.error.HTTPError as e:
            log_error(f"API DELETE error: {e.code} {e.reason} - {full_url}")
            return False

    def get_status(self) -> dict:
        return self._request("/system/status")

    def get_movies(self) -> List[dict]:
        """Get all movies from Radarr."""
        return self._request("/movie")

    def get_movie(self, movie_id: int) -> dict:
        """Get single movie from Radarr."""
        return self._request(f"/movie/{movie_id}")

    def get_movie_files(self, movie_id: int) -> List[dict]:
        """Get movie files for a movie."""
        return self._request(f"/moviefile?movieId={movie_id}")

    def delete_movie_file(self, file_id: int) -> bool:
        """Delete a movie file."""
        return self._delete(f"/moviefile/{file_id}")

    def refresh_movie(self, movie_id: int) -> dict:
        """Trigger refresh for a movie."""
        return self._request("/command", method="POST", data={"name": "RefreshMovie", "movieIds": [movie_id]})

    def get_series(self) -> List[dict]:
        """Get all series from Sonarr."""
        return self._request("/series")

    def get_series_by_id(self, series_id: int) -> dict:
        """Get single series from Sonarr."""
        return self._request(f"/series/{series_id}")

    def get_episodes(self, series_id: int) -> List[dict]:
        """Get all episodes for a series from Sonarr."""
        return self._request(f"/episode?seriesId={series_id}")

    def get_episode_files(self, series_id: int) -> List[dict]:
        """Get episode files for a series."""
        return self._request(f"/episodefile?seriesId={series_id}")

    def delete_episode_file(self, file_id: int) -> bool:
        """Delete an episode file."""
        return self._delete(f"/episodefile/{file_id}")

    def refresh_series(self, series_id: int) -> dict:
        """Trigger refresh for a series."""
        return self._request("/command", method="POST", data={"name": "RefreshSeries", "seriesId": series_id})

    def search_movies(self, movie_ids: List[int]) -> dict:
        """Trigger search for movies in Radarr."""
        return self._request("/command", method="POST", data={"name": "MoviesSearch", "movieIds": movie_ids})

    def search_episodes(self, episode_ids: List[int]) -> dict:
        """Trigger search for episodes in Sonarr."""
        return self._request("/command", method="POST", data={"name": "EpisodeSearch", "episodeIds": episode_ids})


def discover_arr_config(instance: str) -> Optional[Tuple[str, str, str]]:
    """
    Try to discover *arr config from Swizzin installation.
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


# =============================================================================
# Monitored Content Tracking
# =============================================================================

class MonitoredContent:
    """Cache of monitored content from *arr instances."""

    def __init__(self):
        self.radarr_movies: Dict[str, Set[str]] = {}
        self.sonarr_series: Dict[str, Set[str]] = {}
        self.sonarr_wanted: Dict[str, Dict[str, Set[int]]] = {}
        self.radarr_movies_full: Dict[str, List[dict]] = {}
        self.sonarr_series_full: Dict[str, List[dict]] = {}
        self._loaded: Set[str] = set()

    def _normalize_title(self, title: str) -> str:
        """Normalize title for matching."""
        result = unicodedata.normalize('NFKD', title)
        result = ''.join(c for c in result if not unicodedata.combining(c))
        result = result.lower()
        result = result.replace('&', ' and ')
        result = re.sub(r"['\u2019\u2018`]", '', result)  # Strip apostrophes/quotes
        result = re.sub(r'[^\w\s]', ' ', result)
        result = re.sub(r'\s+', ' ', result).strip()
        return result

    def _get_title_variations(self, title: str) -> List[str]:
        """
        Generate multiple title variations for flexible matching.
        E.g., "My Hero Academia (Dubs)" -> ["my hero academia dubs", "my hero academia"]
        E.g., "[Judas] Bleach 001-055 [BD 1080p]" -> ["bleach"]
        E.g., "Dragon Ball Z - 157 - A New Guardian [EN]" -> ["dragon ball z"]
        """
        variations = []

        # Original normalized
        base = self._normalize_title(title)
        variations.append(base)

        # === AKA HANDLING ===
        # Split titles with AKA and try both parts
        # E.g., "Alien3.AKA.Alien.3" -> ["Alien3", "Alien 3"]
        # E.g., "The Glass Dome aka Glaskupan" -> ["The Glass Dome", "Glaskupan"]
        # Match "aka" or "a.k.a" surrounded by any non-word characters
        aka_pattern = r'[^\w](a\.?k\.?a\.?)[^\w]'
        aka_match = re.search(aka_pattern, title, re.IGNORECASE)
        if aka_match:
            # Split on aka/a.k.a patterns (case insensitive)
            parts = re.split(r'[^\w]a\.?k\.?a\.?[^\w]', title, flags=re.IGNORECASE)
            for part in parts:
                part = part.strip(' .-_')
                if part and len(part) > 2:
                    # Normalize the AKA part (convert dots to spaces)
                    part_clean = re.sub(r'\.', ' ', part).strip()
                    part_normalized = self._normalize_title(part_clean)
                    if part_normalized and part_normalized not in variations:
                        variations.append(part_normalized)

        # === PARENTHESIZED ALTERNATE TITLE ===
        # Handle alternate titles in parentheses (common for foreign shows)
        # E.g., "Eteros Ego (The Other Me Catharsis)" -> ["Eteros Ego", "The Other Me Catharsis"]
        # E.g., "La Casa de Papel (Money Heist)" -> ["La Casa de Papel", "Money Heist"]
        paren_match = re.match(r'^(.+?)\s*\(([^)]+)\)\s*$', title)
        if paren_match:
            main_title = paren_match.group(1).strip()
            alt_title = paren_match.group(2).strip()
            # Don't treat years or single words as alternate titles
            if alt_title and len(alt_title) > 4 and not re.match(r'^\d{4}$', alt_title):
                # Add main title (before parentheses)
                main_normalized = self._normalize_title(main_title)
                if main_normalized and main_normalized not in variations:
                    variations.append(main_normalized)
                # Add alternate title (inside parentheses)
                alt_normalized = self._normalize_title(alt_title)
                if alt_normalized and alt_normalized not in variations:
                    variations.append(alt_normalized)

        # === MULTI-TITLE HANDLING ===
        # Handle releases with multiple title variants before year/quality
        # E.g., "John Rambo.Rambo IV.Extended Cut.US.2008" -> ["John Rambo", "Rambo IV"]
        # Pattern: Title segments are capitalized words, not quality/edition markers
        edition_markers = {'extended', 'cut', 'unrated', 'uncut', 'remastered', 'imax', 'directors',
                          'theatrical', 'special', 'edition', 'redux', 'final', 'ultimate', 'criterion'}
        country_markers = {'us', 'uk', 'usa', 'ger', 'fra', 'jpn', 'kor'}
        # Split on dots and look for multiple title-like segments
        segments = re.split(r'\.', title)
        if len(segments) >= 3:  # At least Title1.Title2.Something
            title_candidates = []
            for seg in segments:
                seg_lower = seg.lower().strip()
                # Skip if it's a year, quality, edition, or country marker
                if re.match(r'^(19|20)\d{2}$', seg_lower):
                    break  # Year found, stop looking
                if seg_lower in edition_markers or seg_lower in country_markers:
                    continue
                if re.match(r'^(1080p?|720p?|2160p?|4k|uhd|bluray|remux|webdl|webrip|bdremux)$', seg_lower, re.IGNORECASE):
                    break  # Quality marker found, stop
                # Title segments typically start with uppercase and have multiple chars
                if seg and seg[0].isupper() and len(seg) > 2:
                    title_candidates.append(seg)
            # If we found multiple title candidates, add each as a variation
            if len(title_candidates) >= 2:
                for candidate in title_candidates:
                    # Convert roman numerals in title (IV -> 4) for matching
                    candidate_normalized = self._normalize_title(candidate)
                    if candidate_normalized and candidate_normalized not in variations:
                        variations.append(candidate_normalized)
                    # Also try combining first two candidates (might be single title with dots)
                    combined = ' '.join(title_candidates[:2])
                    combined_normalized = self._normalize_title(combined)
                    if combined_normalized and combined_normalized not in variations:
                        variations.append(combined_normalized)

        # === REPEATED WORD MULTI-TITLE HANDLING ===
        # Detect titles with repeated significant words (indicates two title variants)
        # E.g., "John Rambo Rambo IV" -> split at repeated "Rambo" to get "John Rambo" and "Rambo IV"
        words = title.split()
        if len(words) >= 3:
            # Find repeated words (case-insensitive, min 3 chars)
            word_lower_map = {}
            for i, word in enumerate(words):
                word_lower = word.lower()
                if len(word_lower) >= 3 and word_lower not in edition_markers:
                    if word_lower in word_lower_map:
                        # Found repeated word - split at first occurrence
                        first_idx = word_lower_map[word_lower]
                        second_idx = i
                        # First title: words up to and including first occurrence
                        first_title = ' '.join(words[:first_idx + 1])
                        # Second title: words from second occurrence onward
                        second_title = ' '.join(words[second_idx:])
                        # Add both as variations
                        for part in [first_title, second_title]:
                            part_normalized = self._normalize_title(part)
                            if part_normalized and len(part_normalized) > 2 and part_normalized not in variations:
                                variations.append(part_normalized)
                        break  # Only handle first repeated word
                    else:
                        word_lower_map[word_lower] = i

        # === "FROM THE WORLD OF" HANDLING ===
        # Extract title after "From the World of X: Title" or "From the World of X Title"
        # E.g., "From the World of John Wick Ballerina" -> try "Ballerina"
        from_world_match = re.search(
            r'from\s+the\s+world\s+of\s+[^:]+[:\s]+(.+)$',
            title, re.IGNORECASE
        )
        if from_world_match:
            extracted = from_world_match.group(1).strip()
            extracted_normalized = self._normalize_title(extracted)
            if extracted_normalized and extracted_normalized not in variations:
                variations.append(extracted_normalized)
        # Also try just the last word for cases like "From the World of John Wick Ballerina"
        from_world_simple = re.search(r'from\s+the\s+world\s+of\s+.+\s+(\w+)$', title, re.IGNORECASE)
        if from_world_simple:
            last_word = from_world_simple.group(1).strip()
            if len(last_word) > 3:
                last_normalized = self._normalize_title(last_word)
                if last_normalized and last_normalized not in variations:
                    variations.append(last_normalized)

        # === REVERSED TITLE SEGMENTS ===
        # If title has " - " or ": " separator, try reversed order
        # E.g., "Into Darkness - Star Trek" -> try "Star Trek Into Darkness"
        if ' - ' in title:
            parts = title.split(' - ', 1)
            if len(parts) == 2:
                reversed_title = f"{parts[1]} {parts[0]}"
                reversed_normalized = self._normalize_title(reversed_title)
                if reversed_normalized and reversed_normalized not in variations:
                    variations.append(reversed_normalized)
        if ': ' in title:
            parts = title.split(': ', 1)
            if len(parts) == 2:
                reversed_title = f"{parts[1]} {parts[0]}"
                reversed_normalized = self._normalize_title(reversed_title)
                if reversed_normalized and reversed_normalized not in variations:
                    variations.append(reversed_normalized)

        # === KNOWN FOREIGN TITLE MAPPINGS ===
        # Map known foreign titles to their English equivalents
        # These are shows where the romanized foreign title doesn't contain the English name
        foreign_title_mappings = {
            'eteros ego': 'the other me',
            'eteros egw': 'the other me',
            # Greek show - "Mega" is network prefix, spelling varies (y vs u)
            'mega eutyxismenoi mazi': 'eutuxismenoi mazi',
            'eutyxismenoi mazi': 'eutuxismenoi mazi',
        }
        title_lower = title.lower()
        for foreign, english in foreign_title_mappings.items():
            if title_lower.startswith(foreign):
                # Add the English title as a variation
                english_normalized = self._normalize_title(english)
                if english_normalized and english_normalized not in variations:
                    variations.append(english_normalized)
                # Also try just the base foreign title (without season subtitle)
                foreign_normalized = self._normalize_title(foreign)
                if foreign_normalized and foreign_normalized not in variations:
                    variations.append(foreign_normalized)

        # === FOREIGN PREFIX STRIPPING ===
        # Strip known foreign language prefixes (foreign title + English title)
        # E.g., "Vrana The Crow" -> try "The Crow"
        foreign_prefixes = [
            'vrana', 'il corvo', 'el cuervo', 'le corbeau',  # Crow translations
        ]
        for prefix in foreign_prefixes:
            if title_lower.startswith(prefix + ' '):
                remainder = title[len(prefix):].strip()
                remainder_normalized = self._normalize_title(remainder)
                if remainder_normalized and remainder_normalized not in variations:
                    variations.append(remainder_normalized)

        # === ENGLISH TITLE FROM FOREIGN+ENGLISH COMBOS ===
        # Extract English portion when foreign subtitle is appended
        # E.g., "Wolfs Lupi Solitari" -> try "Wolfs"
        # Pattern: English title followed by Italian/foreign words
        italian_word_pattern = r'\b(lupi|solitari|corvo|diavoli|il|la|los|las|el|un|una)\b'
        if re.search(italian_word_pattern, title, re.IGNORECASE):
            # Try extracting just the first part before foreign words
            english_part_match = re.split(
                r'\s+(?:lupi|solitari|corvo|diavoli|il\s|la\s|los\s|las\s|el\s|un\s|una\s)',
                title, flags=re.IGNORECASE
            )
            if english_part_match and english_part_match[0]:
                english_part = english_part_match[0].strip()
                if len(english_part) > 2:
                    english_normalized = self._normalize_title(english_part)
                    if english_normalized and english_normalized not in variations:
                        variations.append(english_normalized)

        # Strip common suffixes before normalizing
        cleaned = title

        # === ANIME-SPECIFIC PATTERNS ===
        # Remove release group tags at start: [Judas], [SubsPlease], [Yameii], etc.
        cleaned = re.sub(r'^\s*\[[^\]]+\]\s*', '', cleaned)
        # Remove quality/format tags: [BD 1080p], [720p], [HEVC], [x264], etc.
        cleaned = re.sub(r'\s*\[[^\]]*(?:1080p?|720p?|480p?|BD|BluRay|WEB|HEVC|x264|x265|AAC|FLAC|10bit|Hi10P?)[^\]]*\]\s*', '', cleaned, flags=re.IGNORECASE)
        # Remove language tags: [EN], [JPN], [Dual Audio], etc.
        cleaned = re.sub(r'\s*\[(?:EN|JP|JPN|ENG|Dual\s*Audio|Multi)[^\]]*\]\s*', '', cleaned, flags=re.IGNORECASE)
        # Remove any remaining bracketed tags at the end
        cleaned = re.sub(r'\s*\[[^\]]+\]\s*$', '', cleaned)
        # Remove episode info pattern: " - 157 - Episode Title" or " - 01 - Title"
        cleaned = re.sub(r'\s+-\s+\d+\s+-\s+.*$', '', cleaned)
        # Remove episode ranges at end: 001-055, 01-59, 001-999
        cleaned = re.sub(r'\s+\d{2,3}\s*-\s*\d{2,3}\s*$', '', cleaned)
        # Remove single episode numbers at end: 001, 01, 157
        cleaned = re.sub(r'\s+\d{2,3}\s*$', '', cleaned)
        # Remove "Log - Saga Name" patterns (One Piece specific)
        cleaned = re.sub(r'\s+Log\s*-\s*.*$', '', cleaned, flags=re.IGNORECASE)
        # Remove season identifiers: S01, Season 1, etc.
        cleaned = re.sub(r'\s+S\d+\s*$', '', cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r'\s+Season\s+\d+\s*$', '', cleaned, flags=re.IGNORECASE)

        # === GENERAL PATTERNS ===
        # Remove (Dubs), (Sub), (Subbed), (Dubbed), (English Dub), etc.
        cleaned = re.sub(r'\s*\((?:Dubs?|Subs?|Subbed|Dubbed|English\s*(?:Dub|Sub)?|Japanese)\)\s*', ' ', cleaned, flags=re.IGNORECASE)
        # Remove year in parentheses: (2011), (1999)
        cleaned = re.sub(r'\s*\(\d{4}\)\s*', ' ', cleaned)
        # Remove trailing year without parens
        cleaned = re.sub(r'\s+\d{4}\s*$', '', cleaned)
        # Remove "Complete Series", "Complete Collection"
        cleaned = re.sub(r'\s*(?:Complete\s+)?(?:Series|Collection|Season\s*\d*[-\s]*\d*)\s*$', '', cleaned, flags=re.IGNORECASE)
        # Remove "Movies" suffix
        cleaned = re.sub(r'\s*Movies?\s*\d*[-\s]*\d*\s*$', '', cleaned, flags=re.IGNORECASE)
        # Remove "The Series" suffix (e.g., "Pokémon Horizons The Series" -> "Pokémon Horizons")
        cleaned = re.sub(r'\s+The\s+Series\s*$', '', cleaned, flags=re.IGNORECASE)
        # Remove edition keywords: IMAX, Extended, Unrated, Director's Cut, etc.
        cleaned = re.sub(r'\s+(?:IMAX|EXTENDED|UNRATED|UNCUT|THEATRICAL|REMASTERED|REDUX|DIRECTOR\'?S?\s*CUT|SPECIAL\s*EDITION|CRITERION|FINAL\s*CUT|ULTIMATE\s*(?:CUT|EDITION))\s*$', '', cleaned, flags=re.IGNORECASE)
        # Remove " - Foreign Title" suffix (dual language: "Play Dirty - Triplo Gioco" -> "Play Dirty")
        cleaned = re.sub(r'\s+-\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\s*$', '', cleaned)
        # Remove country suffixes: " US", " UK" (case-insensitive for variations)
        # This helps match "The Diplomat US" with "The Diplomat"
        cleaned = re.sub(r'\s+(?:US|UK)$', '', cleaned, flags=re.IGNORECASE)

        cleaned_normalized = self._normalize_title(cleaned)
        if cleaned_normalized and cleaned_normalized not in variations:
            variations.append(cleaned_normalized)

        # Also try just the first part before common delimiters
        # E.g., "Pokemon Complete Series" -> "Pokemon"
        for delimiter in [' complete', ' season', ' movie', ' dub', ' sub', ' the complete', ' log ']:
            idx = cleaned.lower().find(delimiter)
            if idx > 2:  # At least 2 chars before delimiter
                short = cleaned[:idx].strip()
                short_normalized = self._normalize_title(short)
                if short_normalized and len(short_normalized) > 2 and short_normalized not in variations:
                    variations.append(short_normalized)

        # Add variation without common articles/conjunctions for fuzzy matching
        # E.g., "Law and Order" -> "law order"
        for var in list(variations):
            stripped = re.sub(r'\b(and|the|a|an|of|in|on|at|to|for)\b', ' ', var)
            stripped = re.sub(r'\s+', ' ', stripped).strip()
            if stripped and stripped not in variations and len(stripped) > 2:
                variations.append(stripped)

        # Add ultra-normalized variation: no spaces, no punctuation, just alphanumeric
        # Handles cases like "Yu Gi Oh" matching "Yu-Gi-Oh! Go Rush!!"
        # E.g., "Yu Gi Oh GO RUSH" -> "yugiohgorush"
        for var in list(variations):
            ultra = re.sub(r'[^a-z0-9]', '', var.lower())
            if ultra and ultra not in variations and len(ultra) > 2:
                variations.append(ultra)

        # Add singular/plural variations
        # Handles cases like "Campfire Cooking...Absurd Skills" vs "Absurd Skill"
        for var in list(variations):
            words = var.split()
            if words:
                last_word = words[-1]
                # Add singular form if ends with 's' but not 'ss' (e.g., "skills" -> "skill", but not "boss" -> "bos")
                if last_word.endswith('s') and not last_word.endswith('ss') and len(last_word) > 3:
                    singular_word = last_word[:-1]
                    singular_var = ' '.join(words[:-1] + [singular_word]) if len(words) > 1 else singular_word
                    if singular_var and singular_var not in variations:
                        variations.append(singular_var)
                # Add plural form for words that might need 's' (but avoid double-s)
                elif not last_word.endswith('s') and len(last_word) > 2:
                    plural_word = last_word + 's'
                    plural_var = ' '.join(words[:-1] + [plural_word]) if len(words) > 1 else plural_word
                    if plural_var and plural_var not in variations:
                        variations.append(plural_var)

        # Add number word variations (4 -> four, 2 -> two, etc.)
        # Handles cases like "Fantastic 4" vs "Fantastic Four"
        number_words = {
            '1': 'one', '2': 'two', '3': 'three', '4': 'four', '5': 'five',
            '6': 'six', '7': 'seven', '8': 'eight', '9': 'nine', '10': 'ten'
        }
        for var in list(variations):
            # Try replacing numbers with words
            for num, word in number_words.items():
                # Use word boundary to avoid matching within larger numbers
                if re.search(r'\b' + num + r'\b', var):
                    word_var = re.sub(r'\b' + num + r'\b', word, var)
                    if word_var not in variations:
                        variations.append(word_var)
            # Try replacing words with numbers
            for num, word in number_words.items():
                if word in var:
                    num_var = var.replace(word, num)
                    if num_var not in variations:
                        variations.append(num_var)

        # Add base franchise name (strip trailing numbers/roman numerals)
        # E.g., "Rambo IV" -> "Rambo", "Rocky 4" -> "Rocky", "John Wick 3" -> "John Wick"
        for var in list(variations):
            # Strip trailing roman numerals (i, ii, iii, iv, v, vi, vii, viii, ix, x)
            base = re.sub(r'\s+(?:i{1,3}|iv|vi{0,3}|ix|x)$', '', var, flags=re.IGNORECASE)
            # Strip trailing numbers (1-10)
            base = re.sub(r'\s+\d{1,2}$', '', base)
            if base and base != var and len(base) > 2 and base not in variations:
                variations.append(base)

        return variations

    def load_radarr(self, instance: str, api: ArrAPI) -> int:
        """Load monitored movies from Radarr. Returns count."""
        if instance in self._loaded:
            return len(self.radarr_movies.get(instance, set()))

        try:
            movies = api.get_movies()
            monitored = set()
            monitored_full = []

            for movie in movies:
                if movie.get("monitored", False):
                    title = movie.get("title", "")
                    original_title = movie.get("originalTitle", "")
                    year = movie.get("year", "")
                    path = movie.get("path", "")

                    normalized_keys = set()

                    def add_title_variations(t: str):
                        for var in self._get_title_variations(t):
                            monitored.add(var)
                            normalized_keys.add(var)
                            if year:
                                with_year = f"{var} {year}"
                                monitored.add(with_year)
                                normalized_keys.add(with_year)

                    add_title_variations(title)

                    if original_title and original_title != title:
                        add_title_variations(original_title)

                    for alt in movie.get("alternateTitles", []):
                        alt_title = alt.get("title", "")
                        if alt_title:
                            add_title_variations(alt_title)

                    monitored_full.append({
                        "id": movie.get("id"),
                        "title": title,
                        "original_title": original_title if original_title != title else None,
                        "year": year,
                        "path": path,
                        "hasFile": movie.get("hasFile", False),
                        "normalized_keys": sorted(normalized_keys)
                    })

            self.radarr_movies[instance] = monitored
            self.radarr_movies_full[instance] = monitored_full
            self._loaded.add(instance)
            return len([m for m in movies if m.get("monitored", False)])
        except Exception as e:
            log_error(f"Failed to load movies from {instance}: {e}")
            return 0

    def load_sonarr(self, instance: str, api: ArrAPI) -> int:
        """Load monitored series from Sonarr. Returns count."""
        if instance in self._loaded:
            return len(self.sonarr_series.get(instance, set()))

        try:
            series_list = api.get_series()
            monitored = set()
            monitored_full = []
            wanted = {}

            for series in series_list:
                if series.get("monitored", False):
                    title = series.get("title", "")
                    original_title = series.get("originalTitle", "")
                    year = series.get("year", "")
                    path = series.get("path", "")

                    normalized_keys = set()

                    for var in self._get_title_variations(title):
                        monitored.add(var)
                        normalized_keys.add(var)

                    if original_title and original_title != title:
                        for var in self._get_title_variations(original_title):
                            monitored.add(var)
                            normalized_keys.add(var)

                    for alt in series.get("alternateTitles", []):
                        alt_title = alt.get("title", "")
                        if alt_title:
                            for var in self._get_title_variations(alt_title):
                                monitored.add(var)
                                normalized_keys.add(var)

                    monitored_full.append({
                        "id": series.get("id"),
                        "title": title,
                        "original_title": original_title if original_title != title else None,
                        "year": year,
                        "path": path,
                        "normalized_keys": sorted(normalized_keys)
                    })

            self.sonarr_series[instance] = monitored
            self.sonarr_series_full[instance] = monitored_full
            self.sonarr_wanted[instance] = wanted
            self._loaded.add(instance)
            return len([s for s in series_list if s.get("monitored", False)])
        except Exception as e:
            log_error(f"Failed to load series from {instance}: {e}")
            return 0

    def is_movie_monitored(self, instance: str, title: str, year: Optional[str], debug: bool = False) -> bool:
        """Check if a movie is monitored in Radarr."""
        if instance not in self.radarr_movies:
            return True

        monitored = self.radarr_movies[instance]

        for variation in self._get_title_variations(title):
            if year:
                key_with_year = f"{variation} {year}"
                if key_with_year in monitored:
                    return True
            if variation in monitored:
                return True

        if len(title) >= 5:
            base_variation = self._get_title_variations(title)[0]
            for monitored_title in monitored:
                if abs(len(monitored_title) - len(base_variation)) > 5:
                    continue
                ratio = SequenceMatcher(None, base_variation, monitored_title).ratio()
                if ratio >= 0.90:
                    return True

        return False

    def is_series_monitored(self, instance: str, title: str) -> bool:
        """Check if a series is monitored in Sonarr."""
        if instance not in self.sonarr_series:
            return True

        monitored = self.sonarr_series[instance]

        for variation in self._get_title_variations(title):
            if variation in monitored:
                return True

        if len(title) >= 5:
            base_variation = self._get_title_variations(title)[0]
            for monitored_title in monitored:
                if abs(len(monitored_title) - len(base_variation)) > 5:
                    continue
                ratio = SequenceMatcher(None, base_variation, monitored_title).ratio()
                if ratio >= 0.90:
                    return True

        return False

    def get_monitored_items(self, instance: str) -> List[dict]:
        """Get full monitored item data."""
        if instance in self.radarr_movies_full:
            return self.radarr_movies_full[instance]
        if instance in self.sonarr_series_full:
            return self.sonarr_series_full[instance]
        return []


# Global monitored content cache
_monitored_content = MonitoredContent()
_debug_monitored = False


def load_monitored_content(instance: str) -> Tuple[bool, int]:
    """Load monitored content for an instance. Returns (success, count)."""
    config = ARR_INSTANCES.get(instance)
    if not config:
        return False, 0

    discovered = discover_arr_config(instance)
    if not discovered:
        return False, 0

    url, api_key, base_url = discovered

    try:
        api = ArrAPI(url, api_key, base_url)
        status = api.get_status()
        app_name = status.get("appName", instance)
        log_success(f"Connected to {app_name} ({instance})")

        if config["type"] == "radarr":
            count = _monitored_content.load_radarr(instance, api)
        else:
            count = _monitored_content.load_sonarr(instance, api)

        return True, count
    except Exception as e:
        log_warn(f"Could not connect to {instance}: {e}")
        return False, 0


def is_content_monitored(instance: str, title: str, year: Optional[str], media_type: str) -> bool:
    """Check if content is monitored in the specific *arr instance."""
    if media_type == "movie":
        return _monitored_content.is_movie_monitored(instance, title, year, debug=_debug_monitored)
    else:
        return _monitored_content.is_series_monitored(instance, title)


def get_monitored_content() -> MonitoredContent:
    """Get the global monitored content instance."""
    return _monitored_content


# =============================================================================
# Media File Helpers
# =============================================================================

def is_media_file(path: Path) -> bool:
    """Check if path is a media file."""
    return path.suffix.lower() in MEDIA_EXTENSIONS


def folder_has_media(folder: Path) -> bool:
    """Check if folder contains media files."""
    try:
        for entry in os.scandir(folder):
            path = Path(entry.path)
            if is_media_file(path):
                return True
            if entry.is_dir(follow_symlinks=True):
                try:
                    for subentry in os.scandir(entry.path):
                        if is_media_file(Path(subentry.path)):
                            return True
                except (OSError, PermissionError):
                    pass
    except (OSError, PermissionError):
        pass
    return False


def get_media_files(folder: Path) -> List[Path]:
    """Get all media files in a folder (including subdirectories)."""
    media_files = []
    try:
        for entry in os.scandir(folder):
            path = Path(entry.path)
            if is_media_file(path):
                media_files.append(path)
            elif entry.is_dir(follow_symlinks=True):
                try:
                    for subentry in os.scandir(entry.path):
                        subpath = Path(subentry.path)
                        if is_media_file(subpath):
                            media_files.append(subpath)
                except (OSError, PermissionError):
                    pass
    except (OSError, PermissionError):
        pass
    return media_files


# =============================================================================
# ReleaseFolder Class
# =============================================================================

class ReleaseFolder:
    """Represents a release folder with metadata."""

    def __init__(self, path: Path, source_folder: str, download_folder: str = ""):
        self.path = path
        self.name = path.name
        self.source_folder = source_folder
        self.download_folder = download_folder
        self.quality_score = 0
        self.edition: Optional[str] = None
        self.group_key = ""
        self.quality_summary = ""
        self.has_media = False
        self.is_valid_name = False
        self.is_english = False
        self.is_monitored = True
        self.filter_reason = ""
        self.tmdb_result: Optional[TMDBResult] = None
        self.validated_title: Optional[str] = None
        self.validated_year: Optional[str] = None
        self.redirected_instance: Optional[str] = None

    def analyze(self, check_monitored: bool = False):
        """Analyze folder and calculate metadata."""
        self.has_media = folder_has_media(self.path)
        self.quality_score = calculate_quality_score(self.name)
        self.edition = extract_edition(self.name)

        media_type = "series" if self.source_folder in ("series", "series-4k", "anime") else "movie"
        self.group_key = get_group_key(self.name, media_type)
        self.quality_summary = get_quality_summary(self.name)

        if self.source_folder == "anime":
            valid, reason = is_valid_anime_name(self.name)
            self.is_valid_name = valid
            if not valid:
                self.filter_reason = reason
                return
            self.is_english = True
            title = extract_series_title(self.name)
            year = None
            self.validated_title = title
            self.validated_year = year
        else:
            is_series = self.source_folder in ("series", "series-4k")

            valid, reason, tmdb_result = is_valid_media_name_smart(
                self.name, is_series=is_series
            )
            self.is_valid_name = valid
            self.tmdb_result = tmdb_result

            if tmdb_result:
                self.validated_title = tmdb_result.title
                self.validated_year = tmdb_result.year

            if not valid:
                self.filter_reason = reason
                return

            media_type = "series" if is_series else "movie"

            if tmdb_result:
                title = tmdb_result.title
                year = tmdb_result.year
            else:
                clean_name = strip_torrent_prefix(self.name)
                title, year = extract_title_year(clean_name)
                if not title and is_series:
                    title = extract_series_title(clean_name)
                if is_series and title:
                    title = strip_episode_from_title(title)
                self.validated_title = title
                self.validated_year = year

            english, reason = is_english_content_smart(
                self.name, title, year, media_type
            )
            self.is_english = english
            if not english:
                self.filter_reason = reason
                return

        if check_monitored and self.download_folder and title:
            self.is_monitored = is_content_monitored(
                self.download_folder, title, year, media_type
            )
            if not self.is_monitored:
                if self.source_folder in ("series", "series-4k") and media_type == "series":
                    if _monitored_content.is_series_monitored("sonarr-anime", title):
                        self.is_monitored = True
                        self.redirected_instance = "sonarr-anime"
                        self.filter_reason = ""
                    else:
                        self.filter_reason = "not monitored"
                else:
                    self.filter_reason = "not monitored"

    @property
    def is_valid(self) -> bool:
        """Folder passes all filters."""
        return self.has_media and self.is_valid_name and self.is_english and self.is_monitored

    def __repr__(self):
        return f"ReleaseFolder({self.name}, score={self.quality_score})"


# =============================================================================
# API Key Setters (for runtime configuration)
# =============================================================================

def set_tmdb_api_key(key: str):
    """Set TMDB API key at runtime."""
    global TMDB_API_KEY
    TMDB_API_KEY = key


def set_tvdb_api_key(key: str):
    """Set TVDB API key at runtime."""
    global TVDB_API_KEY
    TVDB_API_KEY = key


def set_debug_monitored(debug: bool):
    """Enable/disable monitored content debug output."""
    global _debug_monitored
    _debug_monitored = debug


def get_title_variations(title: str) -> List[str]:
    """
    Generate title variations for flexible matching.

    This is a standalone wrapper around MonitoredContent._get_title_variations()
    for use by external modules like media-library-sync.py.

    Examples:
        "Fantastic 4" -> ["fantastic 4", "fantastic four", ...]
        "Law and Order" -> ["law and order", "law order", ...]
        "Rambo IV" -> ["rambo iv", "rambo 4", "rambo", ...]

    Args:
        title: The title to generate variations for

    Returns:
        List of normalized title variations for matching
    """
    return _monitored_content._get_title_variations(title)


if __name__ == "__main__":
    # Smoke-test is_trash_release() — run with: python3 media_common.py
    _cases = [
        # Bracketed / dotted YTS clones (previously slipped through)
        ("Jack.Ryan.Ghost.War.2026.2160p.4K.WEB.x265.10bit.AAC5.1-[YTS.BZ].mkv", True),
        ("Movie.2024.2160p.WEB-DL.x265-[YTS.MX].mkv", True),
        ("Movie.2024.1080p.BluRay.x264-[YIFY].mkv", True),
        ("Movie.2024.1080p.WEB.x265-YTS.MX.mkv", True),
        ("Movie.2024.1080p.WEB.x265-YTS.LT.mkv", True),
        # Canonical trash groups (already covered by primary regex)
        ("Show.S01E01.720p.HDTV.x264-EZTV.mkv", True),
        ("Movie.2024.1080p.WEB.x264-AXXO.mkv", True),
        ("Movie.2024.1080p.BluRay.x264-PSA.mkv", True),
        ("[Judas] Anime - 01.mkv", True),
        # Bare sub-1080p WEBRip
        ("Movie.2024.480p.WEBRip.x264.mkv", True),
        # Good releases — must NOT be flagged
        ("Movie.2024.2160p.WEB-DL.DDP5.1.Atmos.H.265-FLUX.mkv", False),
        ("Movie.2024.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-FraMeSToR.mkv", False),
        ("Show.S01E01.1080p.WEB-DL.DDP5.1.H.264-NTb.mkv", False),
        ("Movie.2024.2160p.WEB-DL.x265-NTb.mkv", False),
        ("Movie.2024.2160p.WEBRip.x265-GROUP.mkv", False),
        # Usenet obfuscated suffix — trash group still detected after strip
        ("Movie.2024.1080p.WEB.x264-AXXO-Obfuscated.mkv", True),
        # Real group with hash tail — must NOT be flagged
        ("Movie.2024.1080p.WEB-DL.x265-NTb[rarbg].mkv", False),
    ]
    _pass = _fail = 0
    for _name, _expected in _cases:
        _actual = is_trash_release(_name)
        _status = "PASS" if _actual == _expected else "FAIL"
        if _actual == _expected:
            _pass += 1
        else:
            _fail += 1
        print(f"  [{_status}] expected={_expected!s:5} got={_actual!s:5}  {_name}")
    print(f"\n{_pass}/{_pass + _fail} passed")
    sys.exit(0 if _fail == 0 else 1)
