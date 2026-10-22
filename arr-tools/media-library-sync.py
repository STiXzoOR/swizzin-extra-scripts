#!/usr/bin/env python3
"""
Media Library Sync - Direct Library Linking

Symlinks media mount content directly into *arr library folders with:
- Quality-based upgrades (skip MULTI unless REMUX)
- Intelligent series handling with season pack support
- Gap filling for missing content

Usage:
    media-library-sync.py                    # Dry-run all
    media-library-sync.py --apply            # Execute changes
    media-library-sync.py --app radarr       # Movies only
    media-library-sync.py --app sonarr       # Series only
    media-library-sync.py --instance radarr-4k
    media-library-sync.py --no-upgrades      # Fill gaps only
    media-library-sync.py --report-only      # Detailed report
    media-library-sync.py --export report.json  # Export JSON report
    media-library-sync.py --report-limit 50  # Limit console output
"""

import argparse
import json
import os
import re
import sys
import unicodedata
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed

from media_common import (
    # Configuration
    ZURG_BASE, FOLDER_MAPPINGS, ARR_INSTANCES, MEDIA_EXTENSIONS, MAX_WORKERS,
    # Classes
    ArrAPI,
    # Logging
    log, log_success, log_warn, log_error, log_dry, log_skip, log_progress,
    Colors,
    # Quality scoring
    calculate_quality_score, extract_edition, get_quality_summary,
    is_multi_release, is_remux_quality, get_resolution_rank,
    # Title parsing
    extract_title_year, extract_series_title, strip_torrent_prefix,
    # Content filtering
    is_valid_media_name_smart, is_valid_anime_name, is_ai_upscale, is_trash_release,
    # *arr API
    discover_arr_config,
    # Media helpers
    folder_has_media, is_media_file, get_media_files,
    # API key setters
    set_tmdb_api_key, set_tvdb_api_key,
    # Title matching
    get_title_variations,
    # Language detection
    extract_language_tag, has_english_audio,
    # Original language lookup
    get_original_language, LANGUAGE_TAG_TO_CODE,
)

# =============================================================================
# Configuration
# =============================================================================

# Minimum score improvement required for upgrades
UPGRADE_THRESHOLD = 20

# Minimum SequenceMatcher ratio for fuzzy title matching (last resort)
FUZZY_MATCH_THRESHOLD = 0.92

# Derive instance-to-folder mapping from FOLDER_MAPPINGS
# e.g. {"radarr": ["movies"], "radarr-4k": ["movies-4k"], ...}
INSTANCE_FOLDERS: Dict[str, List[str]] = {}
for _zurg_folder, (_instance_name, _) in FOLDER_MAPPINGS.items():
    INSTANCE_FOLDERS.setdefault(_instance_name, []).append(_zurg_folder)

# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class MediaRelease:
    """A release found on a media mount."""
    path: Path
    name: str
    quality_score: int
    quality_summary: str
    edition: Optional[str]
    is_multi: bool
    is_remux: bool
    media_files: List[Path] = field(default_factory=list)
    source_folder: str = ""

    def __repr__(self):
        return f"MediaRelease({self.name}, score={self.quality_score})"


@dataclass
class MediaMovie:
    """Index entry for a movie on a media mount."""
    title: str
    year: Optional[str]
    releases: List[MediaRelease] = field(default_factory=list)

    @property
    def best_release(self) -> Optional[MediaRelease]:
        """Get best release (highest score, preferring non-MULTI)."""
        return self.get_best_release()

    def get_best_release(self, allow_multi: bool = False) -> Optional[MediaRelease]:
        """Get best release (highest score, preferring non-MULTI).

        Args:
            allow_multi: If True, don't penalise MULTI releases (for anime instances).
        """
        if not self.releases:
            return None
        if allow_multi:
            eligible = self.releases
        else:
            # Filter out MULTI unless REMUX
            eligible = [r for r in self.releases if not r.is_multi or r.is_remux]
            if not eligible:
                eligible = self.releases  # Fall back to all if no non-MULTI
        return max(eligible, key=lambda r: r.quality_score)

    def best_release_for_folders(self, allowed_folders: List[str], allow_multi: bool = False) -> Optional[MediaRelease]:
        """Get best release from specific source folders only."""
        folder_releases = [r for r in self.releases if r.source_folder in allowed_folders]
        if not folder_releases:
            return None
        if allow_multi:
            eligible = folder_releases
        else:
            eligible = [r for r in folder_releases if not r.is_multi or r.is_remux]
            if not eligible:
                eligible = folder_releases
        return max(eligible, key=lambda r: r.quality_score)


@dataclass
class MediaEpisode:
    """A single episode file on a media mount."""
    path: Path
    season: int
    episode: int
    quality_score: int
    quality_summary: str
    is_multi: bool
    is_remux: bool
    source_folder: str = ""


@dataclass
class MediaSeasonPack:
    """A season pack on a media mount."""
    path: Path
    name: str
    season: int
    quality_score: int
    quality_summary: str
    is_multi: bool
    is_remux: bool
    episodes: Dict[int, MediaEpisode] = field(default_factory=dict)  # episode_num -> episode
    source_folder: str = ""


@dataclass
class MediaSeries:
    """Index entry for a series on a media mount."""
    title: str
    season_packs: Dict[int, List[MediaSeasonPack]] = field(default_factory=lambda: defaultdict(list))
    individual_episodes: Dict[Tuple[int, int], List[MediaEpisode]] = field(default_factory=lambda: defaultdict(list))


@dataclass
class LibraryMovie:
    """A movie in the *arr library."""
    arr_id: int
    title: str
    year: int
    path: str
    monitored: bool
    has_file: bool
    file_id: Optional[int] = None
    file_path: Optional[str] = None
    file_quality_score: int = 0
    file_quality_summary: str = ""
    alternate_titles: List[str] = field(default_factory=list)


@dataclass
class LibraryEpisode:
    """An episode in the *arr library."""
    arr_id: int
    series_id: int
    season: int
    episode: int
    title: str
    monitored: bool
    has_file: bool
    file_id: Optional[int] = None
    file_path: Optional[str] = None
    file_quality_score: int = 0
    file_quality_summary: str = ""


@dataclass
class LibrarySeries:
    """A series in the *arr library."""
    arr_id: int
    title: str
    year: int
    path: str
    monitored: bool
    episodes: Dict[Tuple[int, int], LibraryEpisode] = field(default_factory=dict)
    alternate_titles: List[str] = field(default_factory=list)


@dataclass
class SyncAction:
    """An action to perform during sync."""
    action_type: str  # 'link', 'upgrade'
    content_type: str  # 'movie', 'episode'
    title: str
    source_path: Path
    target_path: Path
    old_quality: str = ""
    new_quality: str = ""
    arr_file_id: Optional[int] = None
    arr_content_id: int = 0
    instance: str = ""
    source_folder: str = ""
    media_files: List[Path] = field(default_factory=list)


@dataclass
class MatchDiagnostic:
    """Diagnostic info for a failed title match."""
    title: str
    year: Optional[int]
    normalized_key: str
    variations_tried: List[str]
    near_matches: List[Tuple[str, str, float]]  # (index_key, title, similarity)
    instance: str = ""
    content_type: str = ""  # 'movie' or 'series'


# =============================================================================
# Media Index Builder
# =============================================================================

class MediaIndex:
    """Index of all content in media mount folders."""

    def __init__(self, verbose: bool = False, base_path: Path = None):
        self.base_path = base_path or ZURG_BASE
        self.movies: Dict[str, MediaMovie] = {}  # key -> MediaMovie
        self.series: Dict[str, MediaSeries] = {}  # key -> MediaSeries
        self.verbose = verbose
        self._key_cache: Dict[str, str] = {}
        self._movies_ultra: Dict[str, str] = {}  # ultra_key -> primary_key
        self._series_ultra: Dict[str, str] = {}  # ultra_key -> primary_key
        self.all_files_index: Dict[str, Path] = {}  # filename -> __all__/ path

    def _normalize_title(self, title: str) -> str:
        """Normalize title for matching."""
        result = unicodedata.normalize('NFKD', title)
        result = ''.join(c for c in result if not unicodedata.combining(c))
        result = result.lower()
        # Strip country suffixes: (US), (UK), (AU), etc.
        result = re.sub(r'\s*\(\s*(?:us|uk|au|ca|nz)\s*\)\s*', ' ', result)
        result = result.replace('&', ' and ')
        result = re.sub(r"['\u2019\u2018`]", '', result)  # Strip apostrophes/quotes
        result = re.sub(r'[^\w\s]', ' ', result)
        result = re.sub(r'\s+', ' ', result).strip()
        return result

    def _make_movie_key(self, title: str, year: Optional[str]) -> str:
        """Create lookup key for a movie."""
        normalized = self._normalize_title(title)
        if year:
            return f"{normalized}_{year}"
        return normalized

    def _make_series_key(self, title: str) -> str:
        """Create lookup key for a series."""
        return self._normalize_title(title)

    def _make_ultra_key(self, title: str) -> str:
        """Create ultra-normalized key (no spaces, no punctuation)."""
        normalized = self._normalize_title(title)
        return re.sub(r'[^a-z0-9]', '', normalized)

    def _score_match(self, primary_normalized: str, matched_key: str) -> float:
        """Score how well a matched index key matches the original title."""
        key_title = matched_key.rsplit('_', 1)[0] if '_' in matched_key else matched_key
        return SequenceMatcher(None, primary_normalized, key_title).ratio()

    def _parse_episode_info(self, filename: str) -> Optional[Tuple[int, int]]:
        """Extract season and episode number from filename."""
        # Standard: S01E01, s01e01
        match = re.search(r'[Ss](\d{1,2})[Ee](\d{1,3})', filename)
        if match:
            return int(match.group(1)), int(match.group(2))

        # Alternative: 1x01
        match = re.search(r'(\d{1,2})x(\d{2,3})', filename)
        if match:
            return int(match.group(1)), int(match.group(2))

        # Season folder + episode number: "01 - Episode Name.mkv"
        match = re.search(r'^(\d{2,3})(?:\s*[-.]|\s)', filename)
        if match:
            return None  # Need season context

        return None

    def _parse_season_from_folder(self, folder_name: str) -> Optional[int]:
        """Extract season number from folder name."""
        # "Season 1", "Season 01", "S01", "S1"
        match = re.search(r'(?:Season|S)\s*(\d{1,2})', folder_name, re.IGNORECASE)
        if match:
            return int(match.group(1))
        return None

    def _is_season_pack(self, folder_path: Path) -> Tuple[bool, Optional[int]]:
        """Check if folder is a season pack and return season number."""
        name = folder_path.name

        # Check for season indicator in name
        season = self._parse_season_from_folder(name)
        if season:
            return True, season

        # Check for "Complete" with season
        if re.search(r'complete\s+(?:season|s)\s*(\d{1,2})', name, re.IGNORECASE):
            match = re.search(r'(?:season|s)\s*(\d{1,2})', name, re.IGNORECASE)
            if match:
                return True, int(match.group(1))

        # Check for S01-S02 range (multi-season pack)
        if re.search(r'S\d{2}\s*-\s*S\d{2}', name, re.IGNORECASE):
            return False, None  # Multi-season, handle differently

        # Single episode pattern means not a season pack
        if re.search(r'[Ss]\d{1,2}[Ee]\d{1,3}', name):
            return False, None

        return False, None

    def _scan_season_pack(self, folder_path: Path, season: int) -> Dict[int, Path]:
        """Scan a season pack folder and return episode -> path mapping."""
        episodes = {}

        for file_path in folder_path.rglob('*'):
            if not file_path.is_file():
                continue
            if file_path.suffix.lower() not in MEDIA_EXTENSIONS:
                continue

            ep_info = self._parse_episode_info(file_path.name)
            if ep_info:
                ep_season, ep_num = ep_info
                if ep_season == season:
                    episodes[ep_num] = file_path
            else:
                # Try to extract just episode number for season folders
                match = re.search(r'[Ee](\d{1,3})|^(\d{2,3})(?:\s*[-.]|\s)', file_path.name)
                if match:
                    ep_num = int(match.group(1) or match.group(2))
                    episodes[ep_num] = file_path

        return episodes

    def scan_movies(self, folders: List[str] = None):
        """Scan media mount movie folders and build index."""
        if folders is None:
            folders = ["movies", "movies-4k"]

        for folder_name in folders:
            folder_path = self.base_path / folder_name
            if not folder_path.exists():
                log_warn(f"Folder not found: {folder_path}")
                continue

            log(f"Scanning {folder_path}...")
            entries = list(folder_path.iterdir())
            total = len(entries)

            for i, entry in enumerate(entries):
                if not entry.is_dir():
                    continue

                log_progress(i + 1, total, entry.name[:50])

                # Skip AI upscales
                if is_ai_upscale(entry.name):
                    continue

                # Extract title and year
                title, year = extract_title_year(entry.name)
                if not title:
                    continue

                # Check for media files
                media_files = get_media_files(entry)
                if not media_files:
                    continue

                # Create release
                quality_score = calculate_quality_score(entry.name)
                release = MediaRelease(
                    path=entry,
                    name=entry.name,
                    quality_score=quality_score,
                    quality_summary=get_quality_summary(entry.name),
                    edition=extract_edition(entry.name),
                    is_multi=is_multi_release(entry.name),
                    is_remux=is_remux_quality(entry.name),
                    media_files=media_files,
                    source_folder=folder_name,
                )

                # Add to index under primary key
                key = self._make_movie_key(title, year)
                if key not in self.movies:
                    self.movies[key] = MediaMovie(title=title, year=year)
                zurg_movie = self.movies[key]
                zurg_movie.releases.append(release)

                # Index under title variations for broader matching
                for variation in get_title_variations(title):
                    var_key = self._make_movie_key(variation, year)
                    if var_key != key and var_key not in self.movies:
                        self.movies[var_key] = zurg_movie

                # Populate ultra-normalized secondary index
                ultra_key = self._make_ultra_key(title)
                if ultra_key and len(ultra_key) > 4:
                    if ultra_key not in self._movies_ultra:
                        self._movies_ultra[ultra_key] = key

            print()  # Clear progress line
            log_success(f"Indexed {len(self.movies)} movie keys from {folder_name}")

    def scan_series(self, folders: List[str] = None):
        """Scan media mount series folders and build index."""
        if folders is None:
            folders = ["series", "series-4k", "anime"]

        for folder_name in folders:
            folder_path = self.base_path / folder_name
            if not folder_path.exists():
                log_warn(f"Folder not found: {folder_path}")
                continue

            log(f"Scanning {folder_path}...")
            entries = list(folder_path.iterdir())
            total = len(entries)

            for i, entry in enumerate(entries):
                if not entry.is_dir():
                    continue

                log_progress(i + 1, total, entry.name[:50])

                # Skip AI upscales
                if is_ai_upscale(entry.name):
                    continue

                # Extract series title
                series_title = extract_series_title(entry.name)
                if not series_title:
                    continue

                quality_score = calculate_quality_score(entry.name)
                is_multi = is_multi_release(entry.name)
                is_remux = is_remux_quality(entry.name)
                quality_summary = get_quality_summary(entry.name)

                # Check if it's a season pack
                is_pack, season = self._is_season_pack(entry)

                key = self._make_series_key(series_title)
                if key not in self.series:
                    self.series[key] = MediaSeries(title=series_title)
                zurg_series = self.series[key]

                # Index under title variations for broader matching
                for variation in get_title_variations(series_title):
                    var_key = self._make_series_key(variation)
                    if var_key != key and var_key not in self.series:
                        self.series[var_key] = zurg_series

                # Populate ultra-normalized secondary index
                ultra_key = self._make_ultra_key(series_title)
                if ultra_key and len(ultra_key) > 4:
                    if ultra_key not in self._series_ultra:
                        self._series_ultra[ultra_key] = key

                if is_pack and season:
                    # Scan season pack for episodes
                    ep_paths = self._scan_season_pack(entry, season)
                    episodes = {}
                    for ep_num, ep_path in ep_paths.items():
                        episodes[ep_num] = MediaEpisode(
                            path=ep_path,
                            season=season,
                            episode=ep_num,
                            quality_score=quality_score,
                            quality_summary=quality_summary,
                            is_multi=is_multi,
                            is_remux=is_remux,
                            source_folder=folder_name,
                        )

                    pack = MediaSeasonPack(
                        path=entry,
                        name=entry.name,
                        season=season,
                        quality_score=quality_score,
                        quality_summary=quality_summary,
                        is_multi=is_multi,
                        is_remux=is_remux,
                        episodes=episodes,
                        source_folder=folder_name,
                    )
                    self.series[key].season_packs[season].append(pack)
                else:
                    # Individual episode or complete series folder
                    # Scan for episode files
                    for file_path in entry.rglob('*'):
                        if not file_path.is_file():
                            continue
                        if file_path.suffix.lower() not in MEDIA_EXTENSIONS:
                            continue

                        ep_info = self._parse_episode_info(file_path.name)
                        if ep_info:
                            ep_season, ep_num = ep_info
                            episode = MediaEpisode(
                                path=file_path,
                                season=ep_season,
                                episode=ep_num,
                                quality_score=quality_score,
                                quality_summary=quality_summary,
                                is_multi=is_multi,
                                is_remux=is_remux,
                                source_folder=folder_name,
                            )
                            self.series[key].individual_episodes[(ep_season, ep_num)].append(episode)

            print()  # Clear progress line
            log_success(f"Indexed {len(self.series)} unique series from {folder_name}")

    def build_all_index(self):
        """Build index of all files in __all__ folder for fast lookup."""
        all_folder = self.base_path / "__all__"
        if not all_folder.exists():
            log_warn(f"__all__ folder not found at {all_folder}, skipping resolution")
            return

        log(f"Building file index from {all_folder}...")
        count = 0
        for f in all_folder.rglob("*"):
            if f.is_file() and f.suffix.lower() in MEDIA_EXTENSIONS:
                self.all_files_index[f.name] = f
                self.all_files_index[f.name.lower()] = f
                count += 1
                if count % 5000 == 0:
                    log(f"  Indexed {count} files...")
        log_success(f"Indexed {count} files from __all__")

    def find_movie(self, title: str, year: Optional[int]) -> Optional[MediaMovie]:
        """Find a movie in the index using title variations.

        Uses best-match scoring instead of first-match to avoid false matches
        when franchise base names collide with sequels/spinoffs.
        """
        year_str = str(year) if year else None
        primary_normalized = self._normalize_title(title)
        variations = get_title_variations(title)

        def _year_ok(movie: MediaMovie) -> bool:
            """Check if movie year is within ±1 of target year."""
            if year_str is None:
                return True
            if movie.year:
                try:
                    return abs(int(movie.year) - int(year_str)) <= 1
                except (ValueError, TypeError):
                    pass
            return year_str is None

        best_score = 0.0
        best_movie: Optional[MediaMovie] = None

        # Phase 1 — Exact matches (with year)
        for i, variation in enumerate(variations):
            key = self._make_movie_key(variation, year_str)
            if key in self.movies:
                if i == 0:
                    return self.movies[key]
                score = self._score_match(primary_normalized, key)
                if score > best_score:
                    best_score = score
                    best_movie = self.movies[key]

        # Phase 1b — Exact matches (without year, validate year separately)
        for i, variation in enumerate(variations):
            key_no_year = self._make_movie_key(variation, None)
            if key_no_year in self.movies:
                movie = self.movies[key_no_year]
                if _year_ok(movie):
                    if i == 0 and year_str is None:
                        return movie
                    score = self._score_match(primary_normalized, key_no_year)
                    if score > best_score:
                        best_score = score
                        best_movie = movie

        if best_score >= 0.95:
            return best_movie

        # Phase 2 — Ultra-normalized matches
        for variation in variations:
            ultra = self._make_ultra_key(variation)
            if ultra and len(ultra) > 4:
                if ultra in self._movies_ultra:
                    primary_key = self._movies_ultra[ultra]
                    movie = self.movies.get(primary_key)
                    if movie and _year_ok(movie):
                        score = self._score_match(primary_normalized, primary_key)
                        if score > best_score:
                            best_score = score
                            best_movie = movie

        if best_score >= 0.90:
            return best_movie

        # Phase 3 — Prefix matches (safe direction only: idx_key starts with variation)
        for variation in variations:
            key_no_year = self._make_movie_key(variation, None)
            for idx_key, movie in self.movies.items():
                if idx_key.startswith(key_no_year):
                    if _year_ok(movie):
                        score = self._score_match(primary_normalized, idx_key)
                        if score > best_score:
                            best_score = score
                            best_movie = movie

        # Phase 4 — Fuzzy matching (last resort)
        if len(primary_normalized) >= 5:
            for idx_key, movie in self.movies.items():
                idx_title = idx_key.rsplit('_', 1)[0] if '_' in idx_key else idx_key
                if abs(len(idx_title) - len(primary_normalized)) > max(5, len(primary_normalized) * 0.2):
                    continue
                ratio = SequenceMatcher(None, primary_normalized, idx_title).ratio()
                if ratio >= FUZZY_MATCH_THRESHOLD and ratio > best_score:
                    if _year_ok(movie):
                        best_score = ratio
                        best_movie = movie

        return best_movie

    def find_series(self, title: str) -> Optional[MediaSeries]:
        """Find a series in the index using title variations.

        Uses best-match scoring instead of first-match to avoid false matches
        when franchise base names (e.g. 'Yu-Gi-Oh') collide with sequels/spinoffs.
        """
        primary_normalized = self._normalize_title(title)
        variations = get_title_variations(title)

        best_score = 0.0
        best_series: Optional[MediaSeries] = None

        # Phase 1 — Exact matches
        for i, variation in enumerate(variations):
            key = self._make_series_key(variation)
            if key in self.series:
                # Fast path: primary title exact match
                if i == 0:
                    return self.series[key]
                score = self._score_match(primary_normalized, key)
                if score > best_score:
                    best_score = score
                    best_series = self.series[key]

        # Early exit if high-confidence exact match
        if best_score >= 0.95:
            return best_series

        # Phase 2 — Ultra-normalized matches
        for variation in variations:
            ultra = self._make_ultra_key(variation)
            if ultra and len(ultra) > 4:
                if ultra in self._series_ultra:
                    primary_key = self._series_ultra[ultra]
                    if primary_key in self.series:
                        score = self._score_match(primary_normalized, primary_key)
                        if score > best_score:
                            best_score = score
                            best_series = self.series[primary_key]

        # Early exit if high-confidence ultra match
        if best_score >= 0.90:
            return best_series

        # Phase 3 — Prefix matches (safe direction only: idx_key starts with variation)
        for variation in variations:
            key = self._make_series_key(variation)
            for idx_key, series in self.series.items():
                if idx_key.startswith(key):
                    score = self._score_match(primary_normalized, idx_key)
                    if score > best_score:
                        best_score = score
                        best_series = series

        # Phase 4 — Fuzzy matching (last resort)
        if len(primary_normalized) >= 5:
            for idx_key in self.series:
                if abs(len(idx_key) - len(primary_normalized)) > max(5, len(primary_normalized) * 0.2):
                    continue
                ratio = SequenceMatcher(None, primary_normalized, idx_key).ratio()
                if ratio >= FUZZY_MATCH_THRESHOLD and ratio > best_score:
                    best_score = ratio
                    best_series = self.series[idx_key]

        return best_series

    def _compute_near_matches(
        self, normalized_key: str, index: Dict[str, object], threshold: float = 0.7, limit: int = 5
    ) -> List[Tuple[str, str, float]]:
        """Find near-matches in index using SequenceMatcher.

        Pre-filters by length difference to avoid expensive comparisons
        on strings that can never reach the threshold.
        """
        key_len = len(normalized_key)
        # SequenceMatcher.ratio() <= 2*matches/(len_a+len_b), so if lengths
        # differ too much, the ratio can never reach the threshold.
        # Max allowed length difference: key_len * (1 - threshold) / threshold
        max_diff = max(5, int(key_len * (1.0 - threshold) / threshold)) if threshold > 0 else key_len
        scored = []
        for idx_key in index:
            if abs(len(idx_key) - key_len) > max_diff:
                continue
            ratio = SequenceMatcher(None, normalized_key, idx_key).ratio()
            if ratio >= threshold:
                obj = index[idx_key]
                display = getattr(obj, 'title', idx_key)
                scored.append((idx_key, display, round(ratio, 2)))
        scored.sort(key=lambda x: x[2], reverse=True)
        return scored[:limit]

    def find_movie_with_diagnostics(
        self, title: str, year: Optional[int]
    ) -> Tuple[Optional[MediaMovie], Optional[MatchDiagnostic]]:
        """Find movie, returning diagnostics on failure."""
        result = self.find_movie(title, year)
        if result:
            return result, None

        year_str = str(year) if year else None
        variations = get_title_variations(title)
        primary_key = self._make_movie_key(title, year_str)
        variations_tried = [self._make_movie_key(v, year_str) for v in variations]
        near_matches = self._compute_near_matches(primary_key, self.movies)

        diag = MatchDiagnostic(
            title=title,
            year=year,
            normalized_key=primary_key,
            variations_tried=variations_tried,
            near_matches=near_matches,
        )
        return None, diag

    def find_series_with_diagnostics(
        self, title: str
    ) -> Tuple[Optional[MediaSeries], Optional[MatchDiagnostic]]:
        """Find series, returning diagnostics on failure."""
        result = self.find_series(title)
        if result:
            return result, None

        variations = get_title_variations(title)
        primary_key = self._make_series_key(title)
        variations_tried = [self._make_series_key(v) for v in variations]
        near_matches = self._compute_near_matches(primary_key, self.series)

        diag = MatchDiagnostic(
            title=title,
            year=None,
            normalized_key=primary_key,
            variations_tried=variations_tried,
            near_matches=near_matches,
        )
        return None, diag


# =============================================================================
# Library State Manager
# =============================================================================

class LibraryState:
    """Query and track *arr library state."""

    def __init__(self, instance: str, api: ArrAPI, app_type: str):
        self.instance = instance
        self.api = api
        self.app_type = app_type  # 'radarr' or 'sonarr'
        self.movies: Dict[str, LibraryMovie] = {}  # key -> movie
        self.series: Dict[str, LibrarySeries] = {}  # key -> series

    def _normalize_title(self, title: str) -> str:
        """Normalize title for matching."""
        result = unicodedata.normalize('NFKD', title)
        result = ''.join(c for c in result if not unicodedata.combining(c))
        result = result.lower()
        # Strip country suffixes: (US), (UK), (AU), etc.
        result = re.sub(r'\s*\(\s*(?:us|uk|au|ca|nz)\s*\)\s*', ' ', result)
        result = result.replace('&', ' and ')
        result = re.sub(r"['\u2019\u2018`]", '', result)  # Strip apostrophes/quotes
        result = re.sub(r'[^\w\s]', ' ', result)
        result = re.sub(r'\s+', ' ', result).strip()
        return result

    def _make_movie_key(self, title: str, year: Optional[int]) -> str:
        """Create lookup key for a movie."""
        normalized = self._normalize_title(title)
        if year:
            return f"{normalized}_{year}"
        return normalized

    def _make_series_key(self, title: str) -> str:
        """Create lookup key for a series."""
        return self._normalize_title(title)

    def load_movies(self):
        """Load all movies from Radarr."""
        if self.app_type != 'radarr':
            return

        log(f"Loading movies from {self.instance}...")
        try:
            movies = self.api.get_movies()
        except Exception as e:
            log_error(f"Failed to load movies: {e}")
            return

        for movie in movies:
            if not movie.get('monitored', False):
                continue

            # Collect alternate titles from API
            alt_titles = []
            original_title = movie.get('originalTitle', '')
            if original_title and original_title != movie['title']:
                alt_titles.append(original_title)
            for alt in movie.get('alternateTitles', []):
                alt_title = alt.get('title', '')
                if alt_title and alt_title != movie['title']:
                    alt_titles.append(alt_title)

            lib_movie = LibraryMovie(
                arr_id=movie['id'],
                title=movie['title'],
                year=movie.get('year', 0),
                path=movie.get('path', ''),
                monitored=movie.get('monitored', False),
                has_file=movie.get('hasFile', False),
                alternate_titles=alt_titles,
            )

            # Get file info if has file
            if lib_movie.has_file and movie.get('movieFile'):
                mf = movie['movieFile']
                lib_movie.file_id = mf.get('id')
                lib_movie.file_path = mf.get('path', '')
                # Calculate quality from path
                if lib_movie.file_path:
                    lib_movie.file_quality_score = calculate_quality_score(lib_movie.file_path)
                    lib_movie.file_quality_summary = get_quality_summary(lib_movie.file_path)

            key = self._make_movie_key(lib_movie.title, lib_movie.year)
            self.movies[key] = lib_movie

            # Index under alternate titles so find_movie can match them
            for alt_title in alt_titles:
                alt_key = self._make_movie_key(alt_title, lib_movie.year)
                if alt_key not in self.movies:
                    self.movies[alt_key] = lib_movie

        log_success(f"Loaded {len(self.movies)} monitored movie keys from {self.instance}")

    def load_series(self):
        """Load all series and episodes from Sonarr."""
        if self.app_type != 'sonarr':
            return

        log(f"Loading series from {self.instance}...")
        try:
            series_list = self.api.get_series()
        except Exception as e:
            log_error(f"Failed to load series: {e}")
            return

        for series in series_list:
            if not series.get('monitored', False):
                continue

            # Collect alternate titles from API
            alt_titles = []
            original_title = series.get('originalTitle', '')
            if original_title and original_title != series['title']:
                alt_titles.append(original_title)
            for alt in series.get('alternateTitles', []):
                alt_title = alt.get('title', '')
                if alt_title and alt_title != series['title']:
                    alt_titles.append(alt_title)

            lib_series = LibrarySeries(
                arr_id=series['id'],
                title=series['title'],
                year=series.get('year', 0),
                path=series.get('path', ''),
                monitored=series.get('monitored', False),
                alternate_titles=alt_titles,
            )

            # Load episodes
            try:
                episodes = self.api.get_episodes(series['id'])
                ep_files = {ef['id']: ef for ef in self.api.get_episode_files(series['id'])}
            except Exception as e:
                log_warn(f"Failed to load episodes for {series['title']}: {e}")
                continue

            for ep in episodes:
                if not ep.get('monitored', False):
                    continue

                lib_ep = LibraryEpisode(
                    arr_id=ep['id'],
                    series_id=series['id'],
                    season=ep.get('seasonNumber', 0),
                    episode=ep.get('episodeNumber', 0),
                    title=ep.get('title', ''),
                    monitored=ep.get('monitored', False),
                    has_file=ep.get('hasFile', False),
                )

                if lib_ep.has_file and ep.get('episodeFileId'):
                    ef = ep_files.get(ep['episodeFileId'])
                    if ef:
                        lib_ep.file_id = ef.get('id')
                        lib_ep.file_path = ef.get('path', '')
                        if lib_ep.file_path:
                            lib_ep.file_quality_score = calculate_quality_score(lib_ep.file_path)
                            lib_ep.file_quality_summary = get_quality_summary(lib_ep.file_path)

                lib_series.episodes[(lib_ep.season, lib_ep.episode)] = lib_ep

            key = self._make_series_key(lib_series.title)
            self.series[key] = lib_series

            # Index under alternate titles so find_series can match them
            for alt_title in alt_titles:
                alt_key = self._make_series_key(alt_title)
                if alt_key not in self.series:
                    self.series[alt_key] = lib_series

        log_success(f"Loaded {len(self.series)} monitored series keys from {self.instance}")

    def find_movie(self, title: str, year: Optional[int]) -> Optional[LibraryMovie]:
        """Find a movie in the library using title variations."""
        primary_normalized = self._normalize_title(title)
        variations = get_title_variations(title)

        best_score = 0.0
        best_movie: Optional[LibraryMovie] = None

        # Phase 1 — Exact matches (with year)
        for i, variation in enumerate(variations):
            key = self._make_movie_key(variation, year)
            if key in self.movies:
                if i == 0:
                    return self.movies[key]
                key_title = key.rsplit('_', 1)[0] if '_' in key else key
                score = SequenceMatcher(None, primary_normalized, key_title).ratio()
                if score > best_score:
                    best_score = score
                    best_movie = self.movies[key]

        # Phase 1b — Exact matches (without year)
        for i, variation in enumerate(variations):
            key_no_year = self._make_movie_key(variation, None)
            if key_no_year in self.movies:
                if i == 0 and year is None:
                    return self.movies[key_no_year]
                score = SequenceMatcher(None, primary_normalized, key_no_year).ratio()
                if score > best_score:
                    best_score = score
                    best_movie = self.movies[key_no_year]

        if best_score >= 0.95:
            return best_movie

        # Phase 2 — Prefix matches (safe direction only)
        for variation in variations:
            key_no_year = self._make_movie_key(variation, None)
            for lib_key, movie in self.movies.items():
                if lib_key.startswith(key_no_year):
                    lib_title = lib_key.rsplit('_', 1)[0] if '_' in lib_key else lib_key
                    score = SequenceMatcher(None, primary_normalized, lib_title).ratio()
                    if score > best_score:
                        best_score = score
                        best_movie = movie

        return best_movie

    def find_series(self, title: str) -> Optional[LibrarySeries]:
        """Find a series in the library using title variations."""
        primary_normalized = self._normalize_title(title)
        variations = get_title_variations(title)

        best_score = 0.0
        best_series: Optional[LibrarySeries] = None

        # Phase 1 — Exact matches
        for i, variation in enumerate(variations):
            key = self._make_series_key(variation)
            if key in self.series:
                if i == 0:
                    return self.series[key]
                score = SequenceMatcher(None, primary_normalized, key).ratio()
                if score > best_score:
                    best_score = score
                    best_series = self.series[key]

        if best_score >= 0.95:
            return best_series

        # Phase 2 — Prefix matches (safe direction only)
        for variation in variations:
            key = self._make_series_key(variation)
            for lib_key, series in self.series.items():
                if lib_key.startswith(key):
                    score = SequenceMatcher(None, primary_normalized, lib_key).ratio()
                    if score > best_score:
                        best_score = score
                        best_series = series

        return best_series


# =============================================================================
# Sync Engine
# =============================================================================

# Short language codes that appear in release names (after quality tags)
FOREIGN_SHORT_CODES = re.compile(
    r'[\.\s\-_](FR|FRE|FRA|VOSTFR|TRUEFRENCH'
    r'|IT|ITA'
    r'|RU|RUS'
    r'|UKR|UA'
    r'|DE|GER'
    r'|ES|SPA'
    r'|PT|POR'
    r'|PL|POL'
    r'|CZ|CZE'
    r'|NL|DUT'
    r'|RO|ROM'
    r'|HU|HUN'
    r')[\.\s\-_]',
    re.IGNORECASE,
)

# Map short language codes in release names to ISO 639-1 for TMDB comparison
FOREIGN_SHORT_TO_ISO = {
    'fr': 'fr', 'fre': 'fr', 'fra': 'fr', 'vostfr': 'fr', 'truefrench': 'fr',
    'it': 'it', 'ita': 'it',
    'ru': 'ru', 'rus': 'ru',
    'ukr': 'uk', 'ua': 'uk',
    'de': 'de', 'ger': 'de',
    'es': 'es', 'spa': 'es',
    'pt': 'pt', 'por': 'pt',
    'pl': 'pl', 'pol': 'pl',
    'cz': 'cs', 'cze': 'cs',
    'nl': 'nl', 'dut': 'nl',
    'ro': 'ro', 'rom': 'ro',
    'hu': 'hu', 'hun': 'hu',
    'en': 'en', 'eng': 'en',
    'ja': 'ja', 'jp': 'ja', 'jpn': 'ja', 'jap': 'ja',
    'ko': 'ko', 'kor': 'ko',
    'zh': 'zh', 'chi': 'zh', 'cn': 'zh',
}

# Bracketed multi-language audio tags: [RU+DE], [FR+EN], [DE+RU+EN], etc.
# First code is the default audio track. English-only files don't have this.
BRACKETED_AUDIO_LANGS = re.compile(
    r'\[([A-Z]{2,3})(?:\+[A-Z]{2,3})+\]',
    re.IGNORECASE,
)


class SyncEngine:
    """Coordinates syncing between zurg and *arr libraries."""

    def __init__(
        self,
        zurg_index: MediaIndex,
        library_states: Dict[str, LibraryState],
        apply: bool = False,
        no_upgrades: bool = False,
        verbose: bool = False,
        report_limit: int = 0,
    ):
        self.zurg_index = zurg_index
        self.library_states = library_states
        self.apply = apply
        self.no_upgrades = no_upgrades
        self.verbose = verbose
        self.report_limit = report_limit
        self.actions: List[SyncAction] = []
        self.unmatched: List[MatchDiagnostic] = []
        self._original_lang_cache: Dict[str, Optional[str]] = {}  # "title|year|type" -> iso code
        self.stats = {
            'movies_missing': 0,
            'movies_upgradable': 0,
            'movies_not_found': 0,
            'episodes_missing': 0,
            'episodes_upgradable': 0,
            'episodes_not_found': 0,
            'language_fixes': 0,
            'links_created': 0,
            'upgrades_applied': 0,
            'errors': 0,
        }

    def _resolve_path(self, path: Path) -> Path:
        """Resolve a zurg path to its __all__ canonical path."""
        # Layer 1: Filename lookup in __all__ index (most reliable on FUSE)
        index = self.zurg_index.all_files_index
        if index:
            canonical = index.get(path.name) or index.get(path.name.lower())
            if canonical:
                return canonical

        # Layer 2: Parent symlink resolution
        try:
            for parent in path.parents:
                if parent == ZURG_BASE or parent == ZURG_BASE.parent:
                    break
                if parent.is_symlink():
                    resolved_parent = parent.resolve()
                    relative = path.relative_to(parent)
                    resolved = resolved_parent / relative
                    if resolved.exists():
                        return resolved
        except (OSError, ValueError):
            pass

        # Layer 3: Direct resolve (fallback)
        try:
            resolved = path.resolve()
            if resolved != path and resolved.exists():
                return resolved
        except OSError:
            pass

        return path

    def _should_upgrade(
        self, current_score: int, new_score: int, is_multi: bool, is_remux: bool,
        current_name: str = "", instance: str = "",
        current_summary: str = "", new_summary: str = "",
    ) -> bool:
        """Determine if upgrade is warranted."""
        # Same quality tier — skip (language fix handled in else branch)
        if current_summary and new_summary and current_summary == new_summary:
            return False

        # Skip MULTI unless REMUX — except for anime (dual audio is standard)
        if is_multi and not is_remux and 'anime' not in instance:
            return False

        # Trash-tier current file (YTS/YIFY/WEBRip) — any non-trash improvement counts
        if current_name and is_trash_release(current_name):
            return new_score > current_score

        # Must meet threshold
        if new_score < current_score + UPGRADE_THRESHOLD:
            return False

        return True

    def _is_already_linked_to(self, file_path: str, best_release: MediaRelease) -> bool:
        """Check if existing file is a symlink into the best release's folder."""
        try:
            p = Path(file_path)
            if not p.is_symlink():
                return False
            target = p.resolve()
            # Check if symlink target lives under the best release's directory
            best_dir = best_release.path.resolve()
            return str(target).startswith(str(best_dir) + os.sep) or target.parent == best_dir
        except (OSError, ValueError):
            return False

    def _get_original_language(self, title: str, year: Optional[int], media_type: str) -> Optional[str]:
        """Get original language via TMDB/TVDB, with per-title caching."""
        cache_key = f"{title}|{year}|{media_type}"
        if cache_key in self._original_lang_cache:
            return self._original_lang_cache[cache_key]
        year_str = str(year) if year else None
        lang = get_original_language(title, year_str, media_type)
        self._original_lang_cache[cache_key] = lang
        return lang

    def _is_foreign_audio(self, name: str, instance: str = "", original_language: Optional[str] = None) -> bool:
        """Check if release name indicates foreign default audio.

        If original_language (ISO 639-1) is provided, releases matching
        the content's native language are NOT considered foreign.
        """
        # Explicit full language tag (FRENCH, ITALIAN, RUSSIAN, etc.)
        lang = extract_language_tag(name)
        if lang:
            if 'anime' in instance and lang == 'japanese':
                return False  # Japanese is expected for anime
            # Check against original language
            if original_language:
                tag_code = LANGUAGE_TAG_TO_CODE.get(lang)
                if tag_code and tag_code == original_language:
                    return False  # Native language, not foreign
            return True

        # Short language codes (FR, ITA, RUS, UKR, etc.)
        match = FOREIGN_SHORT_CODES.search(name)
        if match:
            # English audio present alongside foreign codes = multi-language, not foreign
            if has_english_audio(name):
                return False
            if 'anime' in instance:
                # Check if it's just Japanese short codes
                if re.search(r'[\.\s\-_](JP|JPN|JAP)[\.\s\-_]', name, re.IGNORECASE):
                    return False
            # Check against original language
            if original_language:
                short_code = match.group(1).lower()
                iso_code = FOREIGN_SHORT_TO_ISO.get(short_code)
                if iso_code and iso_code == original_language:
                    return False  # Native language, not foreign
            return True

        # Bracketed multi-language audio: [RU+DE], [FR+EN], etc.
        # First code is the default track; English-only files won't have this.
        bracket_match = BRACKETED_AUDIO_LANGS.search(name)
        if bracket_match:
            default_code = bracket_match.group(1).lower()
            default_iso = FOREIGN_SHORT_TO_ISO.get(default_code)
            # Anime: Japanese default is fine
            if 'anime' in instance and default_iso == 'ja':
                return False
            # Check against original language — default must match native
            if original_language and default_iso and default_iso == original_language:
                return False  # Native language default, not foreign
            # Default doesn't match original (or no original to compare)
            if default_iso:
                return True

        # MULTI without English indicator
        if is_multi_release(name) and not has_english_audio(name):
            # MULTI on native non-English content is expected
            if original_language and original_language != 'en':
                return False
            return True

        return False

    def _find_non_foreign_release(
        self,
        zurg_movie: MediaMovie,
        current_resolution: int,
        allowed_folders: List[str],
        instance: str = "",
        original_language: Optional[str] = None,
        current_score: int = 0,
    ) -> Optional[MediaRelease]:
        """Find best non-foreign release at same or better resolution and quality."""
        if allowed_folders:
            releases = [r for r in zurg_movie.releases if r.source_folder in allowed_folders]
        else:
            releases = zurg_movie.releases

        # Filter: non-foreign, non-trash, same or better resolution AND quality
        # Anime: skip trash filter (WEBRip is the standard release format)
        skip_trash = 'anime' in instance
        candidates = []
        for r in releases:
            if self._is_foreign_audio(r.name, instance, original_language):
                continue
            if not skip_trash and is_trash_release(r.name):
                continue
            if r.quality_score < current_score:
                continue
            release_resolution = get_resolution_rank(r.name)
            if release_resolution >= current_resolution:
                candidates.append(r)

        if not candidates:
            return None
        return max(candidates, key=lambda r: r.quality_score)

    def analyze_movies(self, instance: str):
        """Analyze movies for a given instance."""
        state = self.library_states.get(instance)
        if not state or state.app_type != 'radarr':
            return

        # Deduplicate first to get accurate count
        unique_movies = {}
        for key, lib_movie in state.movies.items():
            if lib_movie.arr_id not in unique_movies:
                unique_movies[lib_movie.arr_id] = lib_movie
        total = len(unique_movies)
        log(f"Analyzing {total} movies for {instance}...")
        allowed_folders = INSTANCE_FOLDERS.get(instance, [])

        processed = 0
        for arr_id, lib_movie in unique_movies.items():
            processed += 1
            if processed % 500 == 0:
                log(f"  {processed}/{total} movies analyzed...")

            # Skip completed items - has file and upgrades disabled
            if lib_movie.has_file and self.no_upgrades:
                continue

            # Find in zurg — try primary title first, then alternates
            zurg_movie, diag = self.zurg_index.find_movie_with_diagnostics(
                lib_movie.title, lib_movie.year
            )

            if not zurg_movie and lib_movie.alternate_titles:
                for alt_title in lib_movie.alternate_titles:
                    zurg_movie = self.zurg_index.find_movie(alt_title, lib_movie.year)
                    if zurg_movie:
                        break

            if not zurg_movie:
                self.stats['movies_not_found'] += 1
                if diag:
                    diag.instance = instance
                    diag.content_type = 'movie'
                    self.unmatched.append(diag)
                if self.verbose:
                    hint = ""
                    if diag and diag.near_matches:
                        best_match = diag.near_matches[0]
                        hint = f" (closest: \"{best_match[1]}\" @ {int(best_match[2]*100)}%)"
                    log_skip(f"Not in zurg: {lib_movie.title} ({lib_movie.year}){hint}")
                continue

            # Filter releases to allowed folders for this instance
            # Anime instances: allow MULTI releases (dual audio is standard)
            allow_multi = 'anime' in instance
            if allowed_folders:
                best = zurg_movie.best_release_for_folders(allowed_folders, allow_multi=allow_multi)
            else:
                best = zurg_movie.get_best_release(allow_multi=allow_multi)
            if not best:
                continue

            # Skip foreign audio releases (VOSTFR, FRENCH, etc.)
            orig_lang = self._get_original_language(lib_movie.title, lib_movie.year, 'movie')
            if self._is_foreign_audio(best.name, instance, orig_lang):
                # Try to find a non-foreign alternative
                replacement = self._find_non_foreign_release(
                    zurg_movie, 0, allowed_folders, instance, orig_lang,
                )
                if replacement:
                    best = replacement
                else:
                    continue

            if not lib_movie.has_file:
                # Missing - queue for linking
                self.stats['movies_missing'] += 1
                target_path = Path(lib_movie.path)
                resolved_files = [self._resolve_path(f) for f in best.media_files]

                self.actions.append(SyncAction(
                    action_type='link',
                    content_type='movie',
                    title=f"{lib_movie.title} ({lib_movie.year})",
                    source_path=best.path,
                    target_path=target_path,
                    new_quality=best.quality_summary,
                    arr_content_id=lib_movie.arr_id,
                    instance=instance,
                    source_folder=best.source_folder,
                    media_files=resolved_files,
                ))

            elif not self.no_upgrades:
                # Already symlinked to the best release — nothing to do
                if lib_movie.file_path and self._is_already_linked_to(lib_movie.file_path, best):
                    continue

                # Guard: never downgrade resolution
                if get_resolution_rank(lib_movie.file_path or '') > get_resolution_rank(best.name):
                    continue

                # Has file - check for upgrade
                if self._should_upgrade(
                    lib_movie.file_quality_score,
                    best.quality_score,
                    best.is_multi,
                    best.is_remux,
                    current_name=lib_movie.file_path or '',
                    instance=instance,
                    current_summary=lib_movie.file_quality_summary,
                    new_summary=best.quality_summary,
                ):
                    self.stats['movies_upgradable'] += 1
                    target_path = Path(lib_movie.path)
                    resolved_files = [self._resolve_path(f) for f in best.media_files]

                    self.actions.append(SyncAction(
                        action_type='upgrade',
                        content_type='movie',
                        title=f"{lib_movie.title} ({lib_movie.year})",
                        source_path=best.path,
                        target_path=target_path,
                        old_quality=lib_movie.file_quality_summary,
                        new_quality=best.quality_summary,
                        arr_file_id=lib_movie.file_id,
                        arr_content_id=lib_movie.arr_id,
                        instance=instance,
                        source_folder=best.source_folder,
                        media_files=resolved_files,
                    ))
                else:
                    # Quality upgrade not warranted — check for language fix
                    orig_lang = self._get_original_language(lib_movie.title, lib_movie.year, 'movie')
                    if self._is_foreign_audio(lib_movie.file_path or '', instance, orig_lang):
                        current_res = get_resolution_rank(lib_movie.file_path or '')
                        replacement = self._find_non_foreign_release(
                            zurg_movie, current_res, allowed_folders, instance, orig_lang,
                            current_score=lib_movie.file_quality_score,
                        )
                        if replacement:
                            self.stats['language_fixes'] += 1
                            target_path = Path(lib_movie.path)
                            resolved_files = [self._resolve_path(f) for f in replacement.media_files]

                            self.actions.append(SyncAction(
                                action_type='upgrade',
                                content_type='movie',
                                title=f"{lib_movie.title} ({lib_movie.year}) [LANG FIX]",
                                source_path=replacement.path,
                                target_path=target_path,
                                old_quality=f"{lib_movie.file_quality_summary} (foreign audio)",
                                new_quality=replacement.quality_summary,
                                arr_file_id=lib_movie.file_id,
                                arr_content_id=lib_movie.arr_id,
                                instance=instance,
                                source_folder=replacement.source_folder,
                                media_files=resolved_files,
                            ))
                    continue

        log_success(f"Movies: {self.stats['movies_missing']} missing, "
                   f"{self.stats['movies_upgradable']} upgradable, "
                   f"{self.stats['movies_not_found']} not in zurg")

    def analyze_series(self, instance: str):
        """Analyze series for a given instance."""
        state = self.library_states.get(instance)
        if not state or state.app_type != 'sonarr':
            return

        # Deduplicate first to get accurate count
        unique_series = {}
        for key, lib_series in state.series.items():
            if lib_series.arr_id not in unique_series:
                unique_series[lib_series.arr_id] = lib_series
        total = len(unique_series)
        log(f"Analyzing {total} series for {instance}...")
        allowed_folders = INSTANCE_FOLDERS.get(instance, [])

        processed = 0
        for arr_id, lib_series in unique_series.items():
            processed += 1
            if processed % 200 == 0:
                log(f"  {processed}/{total} series analyzed...")

            # Find in zurg — try primary title first, then alternates
            zurg_series, diag = self.zurg_index.find_series_with_diagnostics(lib_series.title)

            if not zurg_series and lib_series.alternate_titles:
                for alt_title in lib_series.alternate_titles:
                    zurg_series = self.zurg_index.find_series(alt_title)
                    if zurg_series:
                        break

            if not zurg_series:
                self.stats['episodes_not_found'] += len(lib_series.episodes)
                if diag:
                    diag.instance = instance
                    diag.content_type = 'series'
                    self.unmatched.append(diag)
                if self.verbose:
                    hint = ""
                    if diag and diag.near_matches:
                        best_match = diag.near_matches[0]
                        hint = f" (closest: \"{best_match[1]}\" @ {int(best_match[2]*100)}%)"
                    log_skip(f"Not in zurg: {lib_series.title}{hint}")
                continue

            # Pre-fetch original language for foreign audio filtering (cached per title)
            orig_lang = self._get_original_language(lib_series.title, lib_series.year, 'tv')

            # Check each episode
            for (season, episode), lib_ep in lib_series.episodes.items():
                # Skip completed items - has file and upgrades disabled
                if lib_ep.has_file and self.no_upgrades:
                    continue

                # Find best source for this episode
                best_source = None
                best_path = None
                best_score = 0
                best_folder = ""
                is_multi = False
                is_remux = False
                # Anime instances: allow MULTI releases (dual audio is standard)
                allow_multi = 'anime' in instance

                # Check season packs first (filtered by allowed folders)
                if season in zurg_series.season_packs:
                    for pack in zurg_series.season_packs[season]:
                        if allowed_folders and pack.source_folder not in allowed_folders:
                            continue
                        if episode in pack.episodes:
                            if pack.quality_score > best_score:
                                if not pack.is_multi or pack.is_remux or allow_multi:
                                    if not self._is_foreign_audio(pack.name, instance, orig_lang):
                                        best_score = pack.quality_score
                                        best_path = pack.episodes[episode].path
                                        best_source = pack.quality_summary
                                        best_folder = pack.source_folder
                                        is_multi = pack.is_multi
                                        is_remux = pack.is_remux

                # Check individual episodes (filtered by allowed folders)
                ep_key = (season, episode)
                if ep_key in zurg_series.individual_episodes:
                    for ind_ep in zurg_series.individual_episodes[ep_key]:
                        if allowed_folders and ind_ep.source_folder not in allowed_folders:
                            continue
                        if ind_ep.quality_score > best_score:
                            if not ind_ep.is_multi or ind_ep.is_remux or allow_multi:
                                if not self._is_foreign_audio(str(ind_ep.path), instance, orig_lang):
                                    best_score = ind_ep.quality_score
                                    best_path = ind_ep.path
                                    best_source = ind_ep.quality_summary
                                    best_folder = ind_ep.source_folder
                                    is_multi = ind_ep.is_multi
                                    is_remux = ind_ep.is_remux

                if not best_path:
                    self.stats['episodes_not_found'] += 1
                    continue

                if not lib_ep.has_file:
                    # Missing episode
                    self.stats['episodes_missing'] += 1

                    # Determine target path
                    season_folder = Path(lib_series.path) / f"Season {season:02d}"
                    target_path = season_folder / best_path.name

                    self.actions.append(SyncAction(
                        action_type='link',
                        content_type='episode',
                        title=f"{lib_series.title} S{season:02d}E{episode:02d}",
                        source_path=self._resolve_path(best_path),
                        target_path=target_path,
                        new_quality=best_source or "",
                        arr_content_id=lib_series.arr_id,
                        instance=instance,
                        source_folder=best_folder,
                    ))

                elif not self.no_upgrades:
                    # Already symlinked to the best episode file — nothing to do
                    if lib_ep.file_path:
                        try:
                            ep_p = Path(lib_ep.file_path)
                            if ep_p.is_symlink() and ep_p.resolve() == best_path.resolve():
                                continue
                        except OSError:
                            pass

                    # Guard: never downgrade resolution
                    if get_resolution_rank(lib_ep.file_path or '') > get_resolution_rank(str(best_path)):
                        continue

                    # Check for upgrade
                    if self._should_upgrade(lib_ep.file_quality_score, best_score, is_multi, is_remux,
                                            current_name=lib_ep.file_path or '', instance=instance,
                                            current_summary=lib_ep.file_quality_summary,
                                            new_summary=best_source or ""):
                        self.stats['episodes_upgradable'] += 1

                        season_folder = Path(lib_series.path) / f"Season {season:02d}"
                        target_path = season_folder / best_path.name

                        self.actions.append(SyncAction(
                            action_type='upgrade',
                            content_type='episode',
                            title=f"{lib_series.title} S{season:02d}E{episode:02d}",
                            source_path=self._resolve_path(best_path),
                            target_path=target_path,
                            old_quality=lib_ep.file_quality_summary,
                            new_quality=best_source or "",
                            arr_file_id=lib_ep.file_id,
                            arr_content_id=lib_series.arr_id,
                            instance=instance,
                            source_folder=best_folder,
                        ))
                    else:
                        # Quality upgrade not warranted — check for language fix
                        orig_lang = self._get_original_language(lib_series.title, lib_series.year, 'tv')
                        if self._is_foreign_audio(lib_ep.file_path or '', instance, orig_lang):
                            replacement_path = None
                            replacement_score = 0
                            replacement_summary = ""
                            replacement_folder = ""

                            current_res = get_resolution_rank(lib_ep.file_path or '')
                            current_score = lib_ep.file_quality_score
                            # Anime: skip trash filter (WEBRip is the standard release format)
                            skip_trash = 'anime' in instance

                            # Check season packs
                            if season in zurg_series.season_packs:
                                for pack in zurg_series.season_packs[season]:
                                    if allowed_folders and pack.source_folder not in allowed_folders:
                                        continue
                                    if not skip_trash and is_trash_release(pack.name):
                                        continue
                                    if pack.quality_score < current_score:
                                        continue
                                    if episode in pack.episodes:
                                        if not self._is_foreign_audio(pack.name, instance, orig_lang):
                                            ep_res = get_resolution_rank(pack.name)
                                            if ep_res >= current_res and pack.quality_score > replacement_score:
                                                replacement_score = pack.quality_score
                                                replacement_path = pack.episodes[episode].path
                                                replacement_summary = pack.quality_summary
                                                replacement_folder = pack.source_folder

                            # Check individual episodes
                            ep_key = (season, episode)
                            if ep_key in zurg_series.individual_episodes:
                                for ind_ep in zurg_series.individual_episodes[ep_key]:
                                    if allowed_folders and ind_ep.source_folder not in allowed_folders:
                                        continue
                                    if not skip_trash and is_trash_release(str(ind_ep.path)):
                                        continue
                                    if ind_ep.quality_score < current_score:
                                        continue
                                    if not self._is_foreign_audio(str(ind_ep.path), instance, orig_lang):
                                        ep_res = get_resolution_rank(str(ind_ep.path))
                                        if ep_res >= current_res and ind_ep.quality_score > replacement_score:
                                            replacement_score = ind_ep.quality_score
                                            replacement_path = ind_ep.path
                                            replacement_summary = ind_ep.quality_summary
                                            replacement_folder = ind_ep.source_folder

                            if replacement_path:
                                self.stats['language_fixes'] += 1
                                season_folder = Path(lib_series.path) / f"Season {season:02d}"
                                target_path = season_folder / replacement_path.name

                                self.actions.append(SyncAction(
                                    action_type='upgrade',
                                    content_type='episode',
                                    title=f"{lib_series.title} S{season:02d}E{episode:02d} [LANG FIX]",
                                    source_path=self._resolve_path(replacement_path),
                                    target_path=target_path,
                                    old_quality=f"{lib_ep.file_quality_summary} (foreign audio)",
                                    new_quality=replacement_summary or "",
                                    arr_file_id=lib_ep.file_id,
                                    arr_content_id=lib_series.arr_id,
                                    instance=instance,
                                    source_folder=replacement_folder,
                                ))
                        continue

        log_success(f"Episodes: {self.stats['episodes_missing']} missing, "
                   f"{self.stats['episodes_upgradable']} upgradable, "
                   f"{self.stats['episodes_not_found']} not in zurg")

    def execute(self):
        """Execute all queued actions."""
        if not self.actions:
            log("No actions to perform.")
            return

        log(f"\n{'='*60}")
        log(f"{'EXECUTING' if self.apply else 'DRY RUN'}: {len(self.actions)} actions")
        log(f"{'='*60}")

        for action in self.actions:
            self._execute_action(action)

        log(f"\n{'='*60}")
        log("Summary:")
        log(f"  Links created: {self.stats['links_created']}")
        log(f"  Upgrades applied: {self.stats['upgrades_applied']}")
        log(f"  Language fixes: {self.stats['language_fixes']}")
        log(f"  Errors: {self.stats['errors']}")
        log(f"{'='*60}")

    def _execute_action(self, action: SyncAction):
        """Execute a single sync action."""
        if action.action_type == 'link':
            self._execute_link(action)
        elif action.action_type == 'upgrade':
            self._execute_upgrade(action)

    def _execute_link(self, action: SyncAction):
        """Create a symlink for missing content."""
        prefix = "[DRY-RUN] " if not self.apply else ""

        if action.content_type == 'movie':
            # For movies, create per-file symlinks inside target directory
            log(f"{prefix}LINK: {action.title}")
            log(f"  {Colors.DIM}Source: {action.source_path}{Colors.NC}")
            log(f"  {Colors.DIM}Target: {action.target_path}{Colors.NC}")
            log(f"  {Colors.GREEN}Quality: {action.new_quality}{Colors.NC}")

            if self.apply:
                try:
                    if not action.media_files:
                        log_error(f"  No media files found for release")
                        self.stats['errors'] += 1
                        return

                    # Ensure target directory exists
                    action.target_path.mkdir(parents=True, exist_ok=True)

                    # Clean up orphaned folder-level .tmp_link from old code
                    stale_tmp = action.target_path.parent / (action.target_path.name + '.tmp_link')
                    if stale_tmp.is_symlink() or stale_tmp.exists():
                        try:
                            if stale_tmp.is_symlink():
                                stale_tmp.unlink()
                            elif stale_tmp.is_dir():
                                import shutil
                                shutil.rmtree(stale_tmp)
                        except OSError:
                            pass

                    linked = 0
                    for source_file in action.media_files:
                        if not source_file.exists():
                            log_warn(f"  Source file missing: {source_file.name}")
                            continue

                        file_target = action.target_path / source_file.name

                        # Skip existing non-symlinks
                        if file_target.exists() and not file_target.is_symlink():
                            continue

                        # Atomic symlink creation
                        temp_link = file_target.with_suffix(file_target.suffix + '.tmp_link')
                        try:
                            if temp_link.is_symlink() or temp_link.exists():
                                temp_link.unlink()
                            temp_link.symlink_to(source_file)
                            temp_link.rename(file_target)
                        except FileExistsError:
                            if temp_link.is_symlink():
                                temp_link.unlink()
                            if file_target.is_symlink():
                                file_target.unlink()
                                file_target.symlink_to(source_file)
                        linked += 1

                    if linked > 0:
                        self.stats['links_created'] += 1
                        self._trigger_refresh(action)
                    else:
                        log_warn(f"  No files linked")
                        self.stats['errors'] += 1

                except Exception as e:
                    log_error(f"  Failed: {e}")
                    self.stats['errors'] += 1
        else:
            # For episodes, link individual file
            log(f"{prefix}LINK: {action.title}")
            log(f"  {Colors.DIM}Source: {action.source_path}{Colors.NC}")
            log(f"  {Colors.DIM}Target: {action.target_path}{Colors.NC}")
            log(f"  {Colors.GREEN}Quality: {action.new_quality}{Colors.NC}")

            if self.apply:
                try:
                    # Validate source exists before creating symlink
                    if not action.source_path.exists():
                        log_error(f"  Source no longer exists: {action.source_path}")
                        self.stats['errors'] += 1
                        return

                    # Create season folder if needed
                    action.target_path.parent.mkdir(parents=True, exist_ok=True)

                    # Check for existing non-symlink
                    if action.target_path.exists() and not action.target_path.is_symlink():
                        log_warn(f"  Target exists and is not a symlink, skipping")
                        self.stats['errors'] += 1
                        return

                    # Atomic symlink creation using temp file + rename
                    temp_link = action.target_path.with_suffix('.tmp_link')
                    try:
                        if temp_link.is_symlink() or temp_link.exists():
                            temp_link.unlink()
                        temp_link.symlink_to(action.source_path)
                        temp_link.rename(action.target_path)  # Atomic on POSIX
                    except FileExistsError:
                        # Race condition - target appeared, handle gracefully
                        if temp_link.is_symlink():
                            temp_link.unlink()
                        if action.target_path.is_symlink():
                            action.target_path.unlink()
                            action.target_path.symlink_to(action.source_path)

                    self.stats['links_created'] += 1

                    # Trigger refresh
                    self._trigger_refresh(action)

                except Exception as e:
                    log_error(f"  Failed: {e}")
                    self.stats['errors'] += 1

    def _execute_upgrade(self, action: SyncAction):
        """Upgrade existing content with better quality."""
        prefix = "[DRY-RUN] " if not self.apply else ""

        log(f"{prefix}UPGRADE: {action.title}")
        log(f"  {Colors.YELLOW}Old: {action.old_quality}{Colors.NC}")
        log(f"  {Colors.GREEN}New: {action.new_quality}{Colors.NC}")
        log(f"  {Colors.DIM}Source: {action.source_path}{Colors.NC}")

        if self.apply:
            try:
                state = self.library_states.get(action.instance)
                if not state:
                    raise Exception(f"Unknown instance: {action.instance}")

                # Delete existing file via API
                if action.arr_file_id:
                    try:
                        if action.content_type == 'movie':
                            state.api.delete_movie_file(action.arr_file_id)
                        else:
                            state.api.delete_episode_file(action.arr_file_id)
                    except Exception as e:
                        log_error(f"  Failed to delete old file via API: {e}")
                        self.stats['errors'] += 1
                        return

                if action.content_type == 'movie':
                    # Movie: per-file symlinks inside target folder
                    if not action.media_files:
                        log_error(f"  No media files found for release")
                        self.stats['errors'] += 1
                        return

                    action.target_path.mkdir(parents=True, exist_ok=True)

                    # Clean up orphaned folder-level .tmp_link from old code
                    stale_tmp = action.target_path.parent / (action.target_path.name + '.tmp_link')
                    if stale_tmp.is_symlink() or stale_tmp.exists():
                        try:
                            if stale_tmp.is_symlink():
                                stale_tmp.unlink()
                            elif stale_tmp.is_dir():
                                import shutil
                                shutil.rmtree(stale_tmp)
                        except OSError:
                            pass

                    # Remove old symlinks in target folder
                    for existing in action.target_path.iterdir():
                        if existing.is_symlink():
                            existing.unlink()

                    linked = 0
                    for source_file in action.media_files:
                        if not source_file.exists():
                            log_warn(f"  Source file missing: {source_file.name}")
                            continue

                        file_target = action.target_path / source_file.name
                        temp_link = file_target.with_suffix(file_target.suffix + '.tmp_link')
                        try:
                            if temp_link.is_symlink() or temp_link.exists():
                                temp_link.unlink()
                            temp_link.symlink_to(source_file)
                            temp_link.rename(file_target)
                        except FileExistsError:
                            if temp_link.is_symlink():
                                temp_link.unlink()
                            if file_target.is_symlink():
                                file_target.unlink()
                                file_target.symlink_to(source_file)
                        linked += 1

                    if linked > 0:
                        self.stats['upgrades_applied'] += 1
                        self._trigger_refresh(action)
                    else:
                        log_warn(f"  No files linked")
                        self.stats['errors'] += 1
                else:
                    # Episode: single file symlink
                    source_path = self._resolve_path(action.source_path)
                    if not source_path.exists():
                        log_error(f"  Source no longer exists: {source_path}")
                        self.stats['errors'] += 1
                        return

                    action.target_path.parent.mkdir(parents=True, exist_ok=True)
                    temp_link = action.target_path.with_suffix('.tmp_link')
                    try:
                        if temp_link.is_symlink() or temp_link.exists():
                            temp_link.unlink()
                        temp_link.symlink_to(source_path)
                        temp_link.rename(action.target_path)
                    except FileExistsError:
                        if temp_link.is_symlink():
                            temp_link.unlink()
                        if action.target_path.is_symlink():
                            action.target_path.unlink()
                            action.target_path.symlink_to(source_path)

                    self.stats['upgrades_applied'] += 1
                    self._trigger_refresh(action)

            except Exception as e:
                log_error(f"  Failed: {e}")
                self.stats['errors'] += 1

    def _trigger_refresh(self, action: SyncAction):
        """Trigger *arr to rescan the content."""
        state = self.library_states.get(action.instance)
        if not state:
            return

        try:
            if action.content_type == 'movie':
                state.api.refresh_movie(action.arr_content_id)
            else:
                state.api.refresh_series(action.arr_content_id)
        except Exception as e:
            log_warn(f"  Refresh failed (file linked, manual scan needed): {e}")

    def _report_items(self, items: list, limit: int) -> Tuple[list, int]:
        """Return items to display and overflow count based on report limit."""
        if limit <= 0:
            return items, 0
        return items[:limit], max(0, len(items) - limit)

    def print_report(self):
        """Print detailed report of planned actions."""
        if not self.actions and not self.unmatched:
            log("No actions to report.")
            return

        # Group by instance and type
        by_instance: Dict[str, Dict[str, List[SyncAction]]] = defaultdict(lambda: defaultdict(list))
        for action in self.actions:
            by_instance[action.instance][action.action_type].append(action)

        limit = self.report_limit

        log(f"\n{'='*60}")
        log("SYNC REPORT")
        log(f"{'='*60}")

        for instance, by_type in by_instance.items():
            log(f"\n{Colors.BOLD}Instance: {instance}{Colors.NC}")

            if 'link' in by_type:
                log(f"\n  {Colors.GREEN}Missing content to link:{Colors.NC}")
                shown, overflow = self._report_items(by_type['link'], limit)
                for action in shown:
                    log(f"    + {action.title} [{action.new_quality}]")
                if overflow:
                    log(f"    ... and {overflow} more")

            if 'upgrade' in by_type:
                log(f"\n  {Colors.YELLOW}Upgrades available:{Colors.NC}")
                shown, overflow = self._report_items(by_type['upgrade'], limit)
                for action in shown:
                    log(f"    ^ {action.title}: {action.old_quality} -> {action.new_quality}")
                if overflow:
                    log(f"    ... and {overflow} more")

        # Unmatched section
        if self.unmatched:
            log(f"\n{'='*60}")
            log("UNMATCHED ITEMS")
            log(f"{'='*60}")

            # Group unmatched by instance
            unmatched_by_instance: Dict[str, List[MatchDiagnostic]] = defaultdict(list)
            for diag in self.unmatched:
                unmatched_by_instance[diag.instance].append(diag)

            for instance, diags in unmatched_by_instance.items():
                log(f"\n  {Colors.BOLD}{instance}{Colors.NC} ({len(diags)} unmatched):")
                shown, overflow = self._report_items(diags, limit)
                for diag in shown:
                    year_str = f" ({diag.year})" if diag.year else ""
                    hint = ""
                    if diag.near_matches:
                        best = diag.near_matches[0]
                        hint = f" -> closest: \"{best[1]}\" @ {int(best[2]*100)}%"
                    log(f"    ? {diag.title}{year_str}{hint}")
                if overflow:
                    log(f"    ... and {overflow} more")

        log(f"\n{'='*60}")
        log("TOTALS")
        log(f"{'='*60}")
        log(f"  Movies:   {self.stats['movies_missing']} missing, "
            f"{self.stats['movies_upgradable']} upgradable, "
            f"{self.stats['movies_not_found']} not in zurg")
        log(f"  Episodes: {self.stats['episodes_missing']} missing, "
            f"{self.stats['episodes_upgradable']} upgradable, "
            f"{self.stats['episodes_not_found']} not in zurg")
        log(f"  Language fixes: {self.stats['language_fixes']}")
        log(f"\nTotal actions: {len(self.actions)}")
        if self.unmatched:
            log(f"Total unmatched: {len(self.unmatched)}")

    def export_report(self, path: str):
        """Export comprehensive JSON report to file."""
        # Per-instance stats
        per_instance: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
        per_folder: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
        per_quality: Dict[str, int] = defaultdict(int)

        for action in self.actions:
            inst = action.instance
            per_instance[inst]['total'] += 1
            if action.action_type == 'link':
                per_instance[inst]['links'] += 1
            else:
                per_instance[inst]['upgrades'] += 1

            if action.source_folder:
                folder = action.source_folder
                per_folder[folder]['total'] += 1
                per_folder[folder][action.action_type + 's'] += 1

            # Extract quality tier from quality summary
            quality = action.new_quality
            if quality:
                # Use first token as tier (e.g. "4K REMUX" -> "4K", "1080P WEB-DL" -> "1080P")
                tier = quality.split()[0] if quality.split() else quality
                # Normalize 4K variants
                if tier in ('4K', 'UHD'):
                    tier = '2160P'
                per_quality[tier] += 1

        # Also count library sizes per instance
        for inst, state in self.library_states.items():
            if state.app_type == 'radarr':
                per_instance[inst]['library_size'] = len(state.movies)
            else:
                per_instance[inst]['library_size'] = len(state.series)

        # Build actions grouped by instance
        actions_export: Dict[str, Dict[str, list]] = defaultdict(lambda: defaultdict(list))
        for action in self.actions:
            entry = {
                'title': action.title,
                'source_path': str(action.source_path),
                'target_path': str(action.target_path),
                'content_type': action.content_type,
                'source_folder': action.source_folder,
            }
            if action.action_type == 'link':
                entry['quality'] = action.new_quality
                actions_export[action.instance]['links'].append(entry)
            else:
                entry['old_quality'] = action.old_quality
                entry['new_quality'] = action.new_quality
                actions_export[action.instance]['upgrades'].append(entry)

        # Build unmatched export
        unmatched_export = []
        for diag in self.unmatched:
            entry = {
                'title': diag.title,
                'year': diag.year,
                'instance': diag.instance,
                'content_type': diag.content_type,
                'variations_tried': diag.variations_tried,
                'near_matches': [
                    {'title': nm[1], 'similarity': nm[2]}
                    for nm in diag.near_matches
                ],
            }
            unmatched_export.append(entry)

        report = {
            'scan_date': datetime.now().isoformat(),
            'configuration': {
                'instances_processed': list(self.library_states.keys()),
                'upgrade_threshold': UPGRADE_THRESHOLD,
                'instance_folder_mappings': {k: v for k, v in INSTANCE_FOLDERS.items()},
            },
            'stats': {
                'global': {k: v for k, v in self.stats.items()},
                'per_instance': {k: dict(v) for k, v in per_instance.items()},
                'per_folder': {k: dict(v) for k, v in per_folder.items()},
                'per_quality_tier': dict(per_quality),
            },
            'actions': {k: dict(v) for k, v in actions_export.items()},
            'unmatched': unmatched_export,
            'totals': {
                'total_actions': len(self.actions),
                'total_unmatched': len(self.unmatched),
            },
        }

        output_path = Path(path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w') as f:
            json.dump(report, f, indent=2)

        log_success(f"Report exported to {output_path}")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Sync zurg content directly to *arr library folders",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    %(prog)s                        # Dry-run all instances
    %(prog)s --apply                # Execute changes
    %(prog)s --app radarr           # Movies only
    %(prog)s --instance radarr-4k   # Specific instance
    %(prog)s --no-upgrades          # Only fill gaps
    %(prog)s --report-only          # Detailed report
    %(prog)s --export report.json   # Export JSON report
    %(prog)s --report-limit 50      # Limit console output per category
        """
    )

    parser.add_argument('--apply', action='store_true',
                        help='Execute changes (default is dry-run)')
    parser.add_argument('--app', choices=['radarr', 'sonarr'],
                        help='Process only this app type')
    parser.add_argument('--instance',
                        help='Process only this instance (e.g., radarr-4k)')
    parser.add_argument('--no-upgrades', action='store_true',
                        help='Only fill missing content, skip upgrades')
    parser.add_argument('--report-only', action='store_true',
                        help='Show detailed report without executing')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Show detailed output')
    parser.add_argument('--export',
                        help='Export comprehensive JSON report to file')
    parser.add_argument('--report-limit', type=int, default=0,
                        help='Max items per category in console report (0=unlimited, default=0)')
    parser.add_argument('--tmdb-api-key',
                        help='TMDB API key (or set TMDB_API_KEY env var)')

    args = parser.parse_args()

    # Set API keys
    if args.tmdb_api_key:
        set_tmdb_api_key(args.tmdb_api_key)

    log(f"{Colors.BOLD}Zurg Library Sync{Colors.NC}")
    log(f"Mode: {'APPLY' if args.apply else 'DRY-RUN'}")
    if args.no_upgrades:
        log("Upgrades: DISABLED")
    log("")

    # Determine which instances to process
    instances_to_process = []
    for instance, config in ARR_INSTANCES.items():
        if args.instance and instance != args.instance:
            continue
        if args.app and config['type'] != args.app:
            continue
        instances_to_process.append(instance)

    if not instances_to_process:
        log_error("No instances to process. Check --app and --instance arguments.")
        sys.exit(1)

    # Connect to *arr instances
    library_states: Dict[str, LibraryState] = {}
    for instance in instances_to_process:
        config = discover_arr_config(instance)
        if not config:
            log_warn(f"Could not discover config for {instance}, skipping")
            continue

        url, api_key, base_url = config
        api = ArrAPI(url, api_key, base_url)

        try:
            status = api.get_status()
            log_success(f"Connected to {instance} ({status.get('appName', 'unknown')})")
        except Exception as e:
            log_error(f"Failed to connect to {instance}: {e}")
            continue

        app_type = ARR_INSTANCES[instance]['type']
        state = LibraryState(instance, api, app_type)

        if app_type == 'radarr':
            state.load_movies()
        else:
            state.load_series()

        library_states[instance] = state

    if not library_states:
        log_error("No *arr instances connected. Exiting.")
        sys.exit(1)

    # Build zurg index
    zurg_index = MediaIndex(verbose=args.verbose)

    # Scan movies if any radarr instance
    if any(s.app_type == 'radarr' for s in library_states.values()):
        zurg_index.scan_movies()

    # Scan series if any sonarr instance
    if any(s.app_type == 'sonarr' for s in library_states.values()):
        zurg_index.scan_series()

    # Build __all__ file index for symlink resolution
    zurg_index.build_all_index()

    # Create sync engine
    engine = SyncEngine(
        zurg_index=zurg_index,
        library_states=library_states,
        apply=args.apply and not args.report_only,
        no_upgrades=args.no_upgrades,
        verbose=args.verbose,
        report_limit=args.report_limit,
    )

    # Analyze each instance
    for instance, state in library_states.items():
        if state.app_type == 'radarr':
            engine.analyze_movies(instance)
        else:
            engine.analyze_series(instance)

    # Report or execute
    if args.report_only:
        engine.print_report()
    else:
        engine.print_report()
        if args.apply:
            engine.execute()
        else:
            log(f"\n{Colors.YELLOW}This was a dry-run. Use --apply to execute changes.{Colors.NC}")

    # Export JSON report if requested
    if args.export:
        engine.export_report(args.export)


if __name__ == "__main__":
    main()
