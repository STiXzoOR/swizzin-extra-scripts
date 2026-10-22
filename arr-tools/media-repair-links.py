#!/usr/bin/env python3
"""
Media Repair Links - Broken Symlink Repair & Quality Upgrade Tool

Scans *arr library folders for broken symlinks (mount reshuffles,
removed torrents) and searches live media mounts (zurg + torbox) for
matching content to re-symlink — avoiding unnecessary Decypharr re-downloads.

Also finds quality upgrades for existing valid symlinks.

Usage:
    media-repair-links.py                          # Dry-run, scan all
    media-repair-links.py --apply                  # Execute changes
    media-repair-links.py --repair-only            # Only broken links
    media-repair-links.py --upgrades-only          # Only quality upgrades
    media-repair-links.py --app radarr|sonarr|all  # Filter by app type
    media-repair-links.py --instance radarr-4k    # Specific instance
    media-repair-links.py --upgrade-threshold 30   # Custom threshold (default 20)
    media-repair-links.py --apply --refresh        # Execute + trigger *arr rescan
    media-repair-links.py --export report.json     # JSON export of results
    media-repair-links.py --debug                  # Verbose matching output
"""

import argparse
import importlib.util
import json
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from media_common import (
    # Configuration
    ZURG_BASE, TORBOX_BASE, FOLDER_MAPPINGS, ARR_INSTANCES, MEDIA_EXTENSIONS,
    SYMLINKS_BASE, MEDIA_TOOLS_CONFIG,
    # Classes
    ArrAPI,
    # Logging
    log, log_success, log_warn, log_error, log_dry, log_skip, log_progress,
    Colors,
    # Quality scoring
    calculate_quality_score, get_quality_summary, is_multi_release, is_remux_quality,
    # Title parsing
    extract_title_year, extract_series_title, strip_torrent_prefix,
    # *arr API
    discover_arr_config,
    # Title matching
    get_title_variations,
)

# =============================================================================
# Import MediaIndex from media-library-sync.py (hyphenated filename)
# =============================================================================

_spec = importlib.util.spec_from_file_location(
    "media_library_sync", Path(__file__).resolve().parent / "media-library-sync.py"
)
_mls = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mls)
MediaIndex = _mls.MediaIndex
MediaMovie = _mls.MediaMovie
MediaSeries = _mls.MediaSeries
MediaEpisode = _mls.MediaEpisode
MediaSeasonPack = _mls.MediaSeasonPack
UPGRADE_THRESHOLD = _mls.UPGRADE_THRESHOLD

# =============================================================================
# Configuration
# =============================================================================

TORBOX_ALLOWED_FOLDERS = ["__all__"]

# Library layout comes from the shared media-tools config (see media_common):
#   "library_folders": {"<folder under symlinks_base>":
#       {"instance": "radarr", "type": "movie", "zurg_hints": ["movies"],
#        "resolution": "1080p" | "2160p" | null}}
# resolution is the tier the folder holds; it prevents cross-resolution
# upgrades (a 1080p instance never upgrades to 4K content). null = any.
_DEFAULT_LIBRARY_FOLDERS = {
    "movies": {"instance": "radarr", "type": "movie", "zurg_hints": ["movies"], "resolution": "1080p"},
    "series": {"instance": "sonarr", "type": "series", "zurg_hints": ["series"], "resolution": "1080p"},
}
_LIBRARY_CFG = MEDIA_TOOLS_CONFIG.get("library_folders", _DEFAULT_LIBRARY_FOLDERS)

# library folder -> (instance, content_type, zurg_hint_folders)
LIBRARY_FOLDERS = {
    folder: (spec["instance"], spec["type"], list(spec.get("zurg_hints", [folder])))
    for folder, spec in _LIBRARY_CFG.items()
}
LIBRARY_RESOLUTION = {folder: spec.get("resolution") for folder, spec in _LIBRARY_CFG.items()}

# Extra mounts checked before running, but not required to be up
# ("optional_mounts": [["/path", "label"], ...]).
OPTIONAL_MOUNTS_CFG = [(Path(p), label) for p, label in MEDIA_TOOLS_CONFIG.get("optional_mounts", [])]

_IS_4K_RE = re.compile(r'\b(2160p|4k|uhd)\b', re.IGNORECASE)


def _matches_resolution_tier(library_folder: str, quality_text: str) -> bool:
    """Check if a release matches the expected resolution tier for a library folder."""
    expected = LIBRARY_RESOLUTION.get(library_folder)
    if not expected:
        return True  # Unknown folder, allow anything
    is_4k = bool(_IS_4K_RE.search(quality_text))
    if expected == "2160p":
        return is_4k
    else:
        return not is_4k


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class BrokenLink:
    symlink_path: Path
    original_target: str          # os.readlink() result
    library_folder: str           # "movies", "series-4k", etc.
    instance: str                 # "radarr", "sonarr-4k", etc.
    content_type: str             # "movie" or "series"
    title: str                    # From library folder name
    year: Optional[int]
    release_name: str             # From target path (quality info)
    current_quality_score: int
    current_quality_summary: str
    season: Optional[int] = None  # Series only
    episode: Optional[int] = None # Series only
    is_nzbdav: bool = False       # True if target is NZBDav UUID path


@dataclass
class UpgradeCandidate:
    symlink_path: Path
    target_path: Path             # Resolved (valid) target
    library_folder: str
    instance: str
    content_type: str
    title: str
    year: Optional[int]
    current_quality_score: int
    current_quality_summary: str
    season: Optional[int] = None
    episode: Optional[int] = None
    is_nzbdav: bool = False       # True if target is NZBDav UUID path


@dataclass
class RepairAction:
    action_type: str              # "repair" or "upgrade"
    symlink_path: Path
    new_source: Path
    title: str
    old_quality: str
    new_quality: str
    quality_delta: int
    instance: str


# =============================================================================
# Library Scanner
# =============================================================================

def _parse_library_movie_folder(folder_name: str) -> Tuple[Optional[str], Optional[int]]:
    """Parse 'Title (Year) [tmdbid-XXXXX]' folder name."""
    match = re.match(r'^(.+?)\s*\((\d{4})\)', folder_name)
    if match:
        return match.group(1).strip(), int(match.group(2))
    return folder_name, None


def _parse_library_series_folder(folder_name: str) -> Tuple[Optional[str], Optional[int]]:
    """Parse 'Title (Year) [tvdbid-XXXXX]' folder name."""
    match = re.match(r'^(.+?)\s*\((\d{4})\)', folder_name)
    if match:
        return match.group(1).strip(), int(match.group(2))
    return folder_name, None


def _parse_season_number(season_folder: str) -> Optional[int]:
    """Parse 'Season XX' folder name."""
    match = re.match(r'Season\s+(\d+)', season_folder, re.IGNORECASE)
    if match:
        return int(match.group(1))
    return None


def _parse_episode_from_filename(filename: str) -> Tuple[Optional[int], Optional[int]]:
    """Extract season and episode from library filename like 'Title - S01E01 - ...'."""
    match = re.search(r'[Ss](\d{1,2})[Ee](\d{1,3})', filename)
    if match:
        return int(match.group(1)), int(match.group(2))
    return None, None


def _is_nzbdav_target(target: str) -> bool:
    """Check if a symlink target points to NZBDav (UUID-based paths)."""
    return "/nzbdav/" in target


def _extract_quality_from_filename(symlink_path: Path) -> tuple:
    """Extract quality info from the library filename when target is opaque (NZBDav UUID).

    Library filenames contain quality tokens, e.g.:
    'Bluey (2018) - S03E36 - Dirt [DSNP][WEBDL-2160p][EAC3 5.1][x264]-PoF.mkv'

    Returns (release_name, score, summary).
    """
    stem = symlink_path.stem
    return stem, calculate_quality_score(stem), get_quality_summary(stem)


def _extract_release_from_target(target: str) -> str:
    """Extract release folder name from symlink target path.

    Target is like: /mnt/zurg/__all__/Release.Folder.Name/file.mkv
    or:             /mnt/zurg/movies/Release.Folder.Name/file.mkv
    or:             /mnt/torbox/__all__/Release.Folder.Name/file.mkv
    """
    parts = Path(target).parts
    # Find the mount folder component and take the next one
    for i, part in enumerate(parts):
        if part in ('__all__', 'movies', 'movies-4k', 'series', 'series-4k', 'anime', 'torrents'):
            if i + 1 < len(parts):
                return parts[i + 1]
    # Fallback: parent directory name
    return Path(target).parent.name


def scan_library_folder(
    folder_name: str,
    instance: str,
    content_type: str,
    check_upgrades: bool,
    debug: bool = False,
) -> Tuple[List[BrokenLink], List[UpgradeCandidate]]:
    """Scan a library folder for broken symlinks and upgrade candidates."""
    broken_links: List[BrokenLink] = []
    upgrade_candidates: List[UpgradeCandidate] = []
    folder_path = SYMLINKS_BASE / folder_name

    if not folder_path.exists():
        if debug:
            log(f"Skipping {folder_path} (not found)")
        return broken_links, upgrade_candidates

    if content_type == "movie":
        _scan_movie_folder(folder_path, folder_name, instance, check_upgrades, broken_links, upgrade_candidates, debug)
    else:
        _scan_series_folder(folder_path, folder_name, instance, check_upgrades, broken_links, upgrade_candidates, debug)

    return broken_links, upgrade_candidates


def _scan_movie_folder(
    folder_path: Path,
    folder_name: str,
    instance: str,
    check_upgrades: bool,
    broken_links: List[BrokenLink],
    upgrade_candidates: List[UpgradeCandidate],
    debug: bool,
):
    """Scan a movie library folder."""
    try:
        entries = list(os.scandir(folder_path))
    except OSError as e:
        log_error(f"Cannot scan {folder_path}: {e}")
        return

    for entry in entries:
        if not entry.is_dir(follow_symlinks=False):
            continue

        title, year = _parse_library_movie_folder(entry.name)

        # Check each file inside the movie folder
        try:
            files = list(os.scandir(entry.path))
        except OSError:
            continue

        for f in files:
            if not f.is_symlink():
                continue
            if Path(f.name).suffix.lower() not in MEDIA_EXTENSIONS:
                continue

            target = os.readlink(f.path)
            symlink_path = Path(f.path)
            nzbdav = _is_nzbdav_target(target)

            # For NZBDav targets, extract quality from library filename
            if nzbdav:
                release_name, score, summary = _extract_quality_from_filename(symlink_path)
            else:
                release_name = _extract_release_from_target(target)
                score = calculate_quality_score(release_name)
                summary = get_quality_summary(release_name)

            # Check if target is dead (broken symlink)
            if not os.path.exists(f.path):
                broken_links.append(BrokenLink(
                    symlink_path=symlink_path,
                    original_target=target,
                    library_folder=folder_name,
                    instance=instance,
                    content_type="movie",
                    title=title,
                    year=year,
                    release_name=release_name,
                    current_quality_score=score,
                    current_quality_summary=summary,
                    is_nzbdav=nzbdav,
                ))
            elif check_upgrades:
                upgrade_candidates.append(UpgradeCandidate(
                    symlink_path=symlink_path,
                    target_path=Path(os.path.realpath(f.path)),
                    library_folder=folder_name,
                    instance=instance,
                    content_type="movie",
                    title=title,
                    year=year,
                    current_quality_score=score,
                    current_quality_summary=summary,
                    is_nzbdav=nzbdav,
                ))


def _scan_series_folder(
    folder_path: Path,
    folder_name: str,
    instance: str,
    check_upgrades: bool,
    broken_links: List[BrokenLink],
    upgrade_candidates: List[UpgradeCandidate],
    debug: bool,
):
    """Scan a series library folder."""
    try:
        series_entries = list(os.scandir(folder_path))
    except OSError as e:
        log_error(f"Cannot scan {folder_path}: {e}")
        return

    for series_entry in series_entries:
        if not series_entry.is_dir(follow_symlinks=False):
            continue

        title, year = _parse_library_series_folder(series_entry.name)

        # Iterate season folders
        try:
            season_entries = list(os.scandir(series_entry.path))
        except OSError:
            continue

        for season_entry in season_entries:
            if not season_entry.is_dir(follow_symlinks=False):
                continue

            season_num = _parse_season_number(season_entry.name)
            if season_num is None:
                continue

            # Check each file inside the season folder
            try:
                files = list(os.scandir(season_entry.path))
            except OSError:
                continue

            for f in files:
                if not f.is_symlink():
                    continue
                if Path(f.name).suffix.lower() not in MEDIA_EXTENSIONS:
                    continue

                target = os.readlink(f.path)
                symlink_path = Path(f.path)
                nzbdav = _is_nzbdav_target(target)

                ep_season, ep_num = _parse_episode_from_filename(f.name)
                if ep_season is None:
                    ep_season = season_num
                if ep_num is None:
                    continue

                # For NZBDav targets, extract quality from library filename
                if nzbdav:
                    release_name, score, summary = _extract_quality_from_filename(symlink_path)
                else:
                    release_name = _extract_release_from_target(target)
                    score = calculate_quality_score(release_name)
                    summary = get_quality_summary(release_name)

                if not os.path.exists(f.path):
                    broken_links.append(BrokenLink(
                        symlink_path=symlink_path,
                        original_target=target,
                        library_folder=folder_name,
                        instance=instance,
                        content_type="series",
                        title=title,
                        year=year,
                        release_name=release_name,
                        current_quality_score=score,
                        current_quality_summary=summary,
                        season=ep_season,
                        episode=ep_num,
                        is_nzbdav=nzbdav,
                    ))
                elif check_upgrades:
                    upgrade_candidates.append(UpgradeCandidate(
                        symlink_path=symlink_path,
                        target_path=Path(os.path.realpath(f.path)),
                        library_folder=folder_name,
                        instance=instance,
                        content_type="series",
                        title=title,
                        year=year,
                        current_quality_score=score,
                        current_quality_summary=summary,
                        season=ep_season,
                        episode=ep_num,
                        is_nzbdav=nzbdav,
                    ))


# =============================================================================
# Matching Engine
# =============================================================================

def _best_media_file(release) -> Optional[Path]:
    """Pick the largest media file from a release (best proxy for main feature)."""
    if not release.media_files:
        return None
    return max(release.media_files, key=lambda f: f.stat().st_size if f.exists() else 0)


def _best_episode_from_zurg(
    zurg_series: MediaSeries,
    season: int,
    episode: int,
    allowed_folders: List[str],
    allow_multi: bool = False,
) -> Optional[Tuple[Path, int, str]]:
    """Find best episode file for a given season+episode from zurg index.

    Returns (path, quality_score, quality_summary) or None.
    """
    candidates: List[MediaEpisode] = []

    # Check season packs first
    for pack in zurg_series.season_packs.get(season, []):
        if pack.source_folder not in allowed_folders:
            continue
        if not allow_multi and pack.is_multi and not pack.is_remux:
            continue
        ep = pack.episodes.get(episode)
        if ep:
            candidates.append(ep)

    # Check individual episodes
    for ind_ep in zurg_series.individual_episodes.get((season, episode), []):
        if ind_ep.source_folder not in allowed_folders:
            continue
        if not allow_multi and ind_ep.is_multi and not ind_ep.is_remux:
            continue
        candidates.append(ind_ep)

    if not candidates:
        # Retry allowing MULTI if nothing found
        if not allow_multi:
            return _best_episode_from_zurg(zurg_series, season, episode, allowed_folders, allow_multi=True)
        return None

    best = max(candidates, key=lambda e: e.quality_score)
    return best.path, best.quality_score, best.quality_summary


def find_replacement(
    broken: BrokenLink,
    zurg_index: MediaIndex,
    allowed_folders: List[str],
    debug: bool = False,
) -> Optional[RepairAction]:
    """Find a replacement on the zurg mount for a broken symlink."""
    if broken.content_type == "movie":
        movie = zurg_index.find_movie(broken.title, broken.year)
        if not movie:
            if debug:
                log(f"  {Colors.DIM}No zurg match for: {broken.title} ({broken.year}){Colors.NC}")
            return None

        release = movie.best_release_for_folders(allowed_folders)
        if not release:
            if debug:
                log(f"  {Colors.DIM}No release in folders {allowed_folders} for: {broken.title}{Colors.NC}")
            return None

        # Don't cross resolution boundaries
        if not _matches_resolution_tier(broken.library_folder, release.name):
            if debug:
                log(f"  {Colors.DIM}Skipping cross-resolution: {release.name} for {broken.library_folder}{Colors.NC}")
            return None

        media_file = _best_media_file(release)
        if not media_file:
            return None

        return RepairAction(
            action_type="repair",
            symlink_path=broken.symlink_path,
            new_source=media_file,
            title=f"{broken.title} ({broken.year})" if broken.year else broken.title,
            old_quality=broken.current_quality_summary,
            new_quality=release.quality_summary,
            quality_delta=release.quality_score - broken.current_quality_score,
            instance=broken.instance,
        )

    else:  # series
        series = zurg_index.find_series(broken.title)
        if not series:
            if debug:
                log(f"  {Colors.DIM}No zurg match for series: {broken.title}{Colors.NC}")
            return None

        result = _best_episode_from_zurg(series, broken.season, broken.episode, allowed_folders)
        if not result:
            if debug:
                log(f"  {Colors.DIM}No episode S{broken.season:02d}E{broken.episode:02d} for: {broken.title}{Colors.NC}")
            return None

        ep_path, ep_score, ep_summary = result

        # Don't cross resolution boundaries
        if not _matches_resolution_tier(broken.library_folder, ep_summary):
            if debug:
                log(f"  {Colors.DIM}Skipping cross-resolution: {ep_summary} for {broken.library_folder}{Colors.NC}")
            return None

        return RepairAction(
            action_type="repair",
            symlink_path=broken.symlink_path,
            new_source=ep_path,
            title=f"{broken.title} S{broken.season:02d}E{broken.episode:02d}",
            old_quality=broken.current_quality_summary,
            new_quality=ep_summary,
            quality_delta=ep_score - broken.current_quality_score,
            instance=broken.instance,
        )


def find_upgrade(
    candidate: UpgradeCandidate,
    zurg_index: MediaIndex,
    allowed_folders: List[str],
    threshold: int,
    debug: bool = False,
) -> Optional[RepairAction]:
    """Find a quality upgrade on the zurg mount for an existing symlink."""
    if candidate.content_type == "movie":
        movie = zurg_index.find_movie(candidate.title, candidate.year)
        if not movie:
            return None

        release = movie.best_release_for_folders(allowed_folders)
        if not release:
            return None

        # Don't cross resolution boundaries (e.g., 1080p instance -> 4K content)
        if not _matches_resolution_tier(candidate.library_folder, release.name):
            if debug:
                log(f"  {Colors.DIM}Skipping cross-resolution: {release.name} for {candidate.library_folder}{Colors.NC}")
            return None

        media_file = _best_media_file(release)
        if not media_file:
            return None

        delta = release.quality_score - candidate.current_quality_score
        if delta < threshold:
            return None

        # Skip if it's the same file
        if media_file == candidate.target_path:
            return None

        return RepairAction(
            action_type="upgrade",
            symlink_path=candidate.symlink_path,
            new_source=media_file,
            title=f"{candidate.title} ({candidate.year})" if candidate.year else candidate.title,
            old_quality=candidate.current_quality_summary,
            new_quality=release.quality_summary,
            quality_delta=delta,
            instance=candidate.instance,
        )

    else:  # series
        series = zurg_index.find_series(candidate.title)
        if not series:
            return None

        result = _best_episode_from_zurg(series, candidate.season, candidate.episode, allowed_folders)
        if not result:
            return None

        ep_path, ep_score, ep_summary = result

        # Don't cross resolution boundaries
        if not _matches_resolution_tier(candidate.library_folder, ep_summary):
            if debug:
                log(f"  {Colors.DIM}Skipping cross-resolution: {ep_summary} for {candidate.library_folder}{Colors.NC}")
            return None

        delta = ep_score - candidate.current_quality_score
        if delta < threshold:
            return None

        # Skip if it's the same file
        if ep_path == candidate.target_path:
            return None

        return RepairAction(
            action_type="upgrade",
            symlink_path=candidate.symlink_path,
            new_source=ep_path,
            title=f"{candidate.title} S{candidate.season:02d}E{candidate.episode:02d}",
            old_quality=candidate.current_quality_summary,
            new_quality=ep_summary,
            quality_delta=delta,
            instance=candidate.instance,
        )


# =============================================================================
# Multi-mount wrappers (zurg + torbox)
# =============================================================================

def _find_best_replacement(
    broken: BrokenLink,
    media_index: MediaIndex,
    torbox_index: Optional[MediaIndex],
    zurg_folders: List[str],
    debug: bool = False,
) -> Optional[RepairAction]:
    """Search both zurg and torbox indexes, return higher-quality result."""
    zurg_action = find_replacement(broken, media_index, zurg_folders, debug=debug)
    torbox_action = None
    if torbox_index is not None:
        torbox_action = find_replacement(broken, torbox_index, TORBOX_ALLOWED_FOLDERS, debug=debug)
    if zurg_action and torbox_action:
        return torbox_action if torbox_action.quality_delta > zurg_action.quality_delta else zurg_action
    return zurg_action or torbox_action


def _find_best_upgrade(
    candidate: UpgradeCandidate,
    media_index: MediaIndex,
    torbox_index: Optional[MediaIndex],
    zurg_folders: List[str],
    threshold: int,
    debug: bool = False,
) -> Optional[RepairAction]:
    """Search both zurg and torbox indexes, return higher-quality upgrade."""
    zurg_action = find_upgrade(candidate, media_index, zurg_folders, threshold, debug=debug)
    torbox_action = None
    if torbox_index is not None:
        torbox_action = find_upgrade(candidate, torbox_index, TORBOX_ALLOWED_FOLDERS, threshold, debug=debug)
    if zurg_action and torbox_action:
        return torbox_action if torbox_action.quality_delta > zurg_action.quality_delta else zurg_action
    return zurg_action or torbox_action


# =============================================================================
# Atomic Relink
# =============================================================================

def atomic_relink(symlink_path: Path, new_source: Path) -> bool:
    """Atomically replace a symlink with a new target."""
    temp = symlink_path.with_suffix(symlink_path.suffix + '.tmp_link')
    try:
        if temp.exists() or temp.is_symlink():
            temp.unlink()
        temp.symlink_to(new_source)
        temp.rename(symlink_path)  # Atomic on POSIX
        return True
    except OSError as e:
        log_error(f"Failed to relink {symlink_path}: {e}")
        if temp.exists() or temp.is_symlink():
            temp.unlink(missing_ok=True)
        return False


# =============================================================================
# *arr Refresh
# =============================================================================

def refresh_arr_items(
    actions: List[RepairAction],
    debug: bool = False,
):
    """Trigger *arr refresh for affected items."""
    # Group by instance to avoid duplicate API connections
    by_instance: Dict[str, List[RepairAction]] = defaultdict(list)
    for action in actions:
        by_instance[action.instance].append(action)

    for instance, instance_actions in by_instance.items():
        config = discover_arr_config(instance)
        if not config:
            log_warn(f"Cannot discover config for {instance}, skipping refresh")
            continue

        url, api_key, base_url = config
        api = ArrAPI(url, api_key, base_url)
        arr_config = ARR_INSTANCES.get(instance, {})
        app_type = arr_config.get("type", "")

        if app_type == "radarr":
            _refresh_radarr(api, instance, instance_actions, debug)
        elif app_type == "sonarr":
            _refresh_sonarr(api, instance, instance_actions, debug)


def _refresh_radarr(api: ArrAPI, instance: str, actions: List[RepairAction], debug: bool):
    """Refresh affected movies in Radarr."""
    try:
        movies = api.get_movies()
    except Exception as e:
        log_error(f"Failed to get movies from {instance}: {e}")
        return

    # Build title -> movie_id lookup
    title_to_id: Dict[str, int] = {}
    for movie in movies:
        title_to_id[movie['title'].lower()] = movie['id']
        orig = movie.get('originalTitle', '')
        if orig:
            title_to_id[orig.lower()] = movie['id']

    refreshed = set()
    for action in actions:
        # Strip year suffix for lookup
        base_title = re.sub(r'\s*\(\d{4}\)$', '', action.title).strip().lower()
        movie_id = title_to_id.get(base_title)
        if movie_id and movie_id not in refreshed:
            try:
                api.refresh_movie(movie_id)
                refreshed.add(movie_id)
                if debug:
                    log(f"  Refreshed {instance} movie ID {movie_id}: {action.title}")
            except Exception as e:
                log_warn(f"  Failed to refresh {action.title}: {e}")

    if refreshed:
        log_success(f"Refreshed {len(refreshed)} movies in {instance}")


def _refresh_sonarr(api: ArrAPI, instance: str, actions: List[RepairAction], debug: bool):
    """Refresh affected series in Sonarr (batched per series)."""
    try:
        all_series = api.get_series()
    except Exception as e:
        log_error(f"Failed to get series from {instance}: {e}")
        return

    # Build title -> series_id lookup
    title_to_id: Dict[str, int] = {}
    for s in all_series:
        title_to_id[s['title'].lower()] = s['id']

    # Deduplicate: only refresh each series once
    series_to_refresh = set()
    for action in actions:
        # Strip episode suffix for series title
        base_title = re.sub(r'\s+S\d{2}E\d{2,3}$', '', action.title).strip().lower()
        series_id = title_to_id.get(base_title)
        if series_id:
            series_to_refresh.add(series_id)

    refreshed = 0
    for series_id in series_to_refresh:
        try:
            api.refresh_series(series_id)
            refreshed += 1
            if debug:
                log(f"  Refreshed {instance} series ID {series_id}")
        except Exception as e:
            log_warn(f"  Failed to refresh series ID {series_id}: {e}")

    if refreshed:
        log_success(f"Refreshed {refreshed} series in {instance}")


# =============================================================================
# *arr Re-search (for unmatched broken links)
# =============================================================================

def research_unmatched(
    unmatched: Dict[str, List[BrokenLink]],
    debug: bool = False,
):
    """Trigger *arr search for unmatched broken links so they get re-grabbed."""
    for instance, broken_list in unmatched.items():
        # Skip NZBDav items — they self-heal
        actionable = [b for b in broken_list if not b.is_nzbdav]
        if not actionable:
            continue

        config = discover_arr_config(instance)
        if not config:
            log_warn(f"Cannot discover config for {instance}, skipping re-search")
            continue

        url, api_key, base_url = config
        api = ArrAPI(url, api_key, base_url)
        arr_config = ARR_INSTANCES.get(instance, {})
        app_type = arr_config.get("type", "")

        if app_type == "radarr":
            _research_radarr(api, instance, actionable, debug)
        elif app_type == "sonarr":
            _research_sonarr(api, instance, actionable, debug)


def _research_radarr(api: ArrAPI, instance: str, broken_list: List[BrokenLink], debug: bool):
    """Refresh then trigger search for broken movies in Radarr."""
    try:
        movies = api.get_movies()
    except Exception as e:
        log_error(f"Failed to get movies from {instance}: {e}")
        return

    # Build path -> movie lookup (match by library folder path)
    path_to_movie: Dict[str, dict] = {}
    for movie in movies:
        movie_path = movie.get('path', '')
        if movie_path:
            path_to_movie[movie_path.rstrip('/')] = movie

    movie_ids_to_search = set()

    for broken in broken_list:
        # Movie folder is the parent of the symlink
        movie_folder = str(broken.symlink_path.parent)
        movie = path_to_movie.get(movie_folder)
        if not movie:
            if debug:
                log(f"  {Colors.DIM}No Radarr match for path: {movie_folder}{Colors.NC}")
            continue
        movie_ids_to_search.add(movie['id'])

    if not movie_ids_to_search:
        return

    # Refresh first so Radarr detects missing files
    ids = list(movie_ids_to_search)
    refreshed = 0
    for movie_id in ids:
        try:
            api.refresh_movie(movie_id)
            refreshed += 1
        except Exception as e:
            if debug:
                log_warn(f"  Failed to refresh movie {movie_id}: {e}")

    if debug:
        log(f"  Refreshed {refreshed} movies in {instance}")

    # Then trigger search in batches of 50
    for i in range(0, len(ids), 50):
        batch = ids[i:i+50]
        try:
            api.search_movies(batch)
            if debug:
                log(f"  Queued search for {len(batch)} movies in {instance}")
        except Exception as e:
            log_warn(f"  Failed to trigger search in {instance}: {e}")

    log_success(f"Re-search: {len(movie_ids_to_search)} movies in {instance}")


def _research_sonarr(api: ArrAPI, instance: str, broken_list: List[BrokenLink], debug: bool):
    """Refresh then trigger search for broken episodes in Sonarr."""
    try:
        all_series = api.get_series()
    except Exception as e:
        log_error(f"Failed to get series from {instance}: {e}")
        return

    # Build path -> series lookup
    path_to_series: Dict[str, dict] = {}
    for s in all_series:
        s_path = s.get('path', '')
        if s_path:
            path_to_series[s_path.rstrip('/')] = s

    # Group broken by series to batch episode lookups
    series_broken: Dict[int, List[BrokenLink]] = defaultdict(list)
    for broken in broken_list:
        # Series folder is grandparent (symlink -> Season XX -> Series Name)
        series_folder = str(broken.symlink_path.parent.parent)
        series = path_to_series.get(series_folder)
        if not series:
            if debug:
                log(f"  {Colors.DIM}No Sonarr match for path: {series_folder}{Colors.NC}")
            continue
        series_broken[series['id']].append(broken)

    # Refresh all affected series first so Sonarr detects missing files
    refreshed = 0
    for series_id in series_broken:
        try:
            api.refresh_series(series_id)
            refreshed += 1
        except Exception as e:
            if debug:
                log_warn(f"  Failed to refresh series {series_id}: {e}")

    if debug:
        log(f"  Refreshed {refreshed} series in {instance}")

    episode_ids_to_search = []

    for series_id, brokens in series_broken.items():
        try:
            episodes = api.get_episodes(series_id)
        except Exception as e:
            if debug:
                log_warn(f"  Failed to get episodes for series {series_id}: {e}")
            continue

        # Build (season, episode) -> episode_id lookup
        ep_lookup: Dict[Tuple[int, int], int] = {}
        for ep in episodes:
            s = ep.get('seasonNumber')
            e = ep.get('episodeNumber')
            if s is not None and e is not None:
                ep_lookup[(s, e)] = ep['id']

        for broken in brokens:
            ep_id = ep_lookup.get((broken.season, broken.episode))
            if ep_id:
                episode_ids_to_search.append(ep_id)
            elif debug:
                log(f"  {Colors.DIM}No episode match: {broken.title} S{broken.season:02d}E{broken.episode:02d}{Colors.NC}")

    if episode_ids_to_search:
        # Batch search in groups of 50
        for i in range(0, len(episode_ids_to_search), 50):
            batch = episode_ids_to_search[i:i+50]
            try:
                api.search_episodes(batch)
                if debug:
                    log(f"  Queued search for {len(batch)} episodes in {instance}")
            except Exception as e:
                log_warn(f"  Failed to trigger search in {instance}: {e}")

        log_success(f"Re-search: {len(episode_ids_to_search)} episodes in {instance}")


# =============================================================================
# Report Output
# =============================================================================

def print_report(
    repairs: Dict[str, List[RepairAction]],
    unmatched: Dict[str, List[BrokenLink]],
    upgrades: Dict[str, List[RepairAction]],
    applied: bool,
):
    """Print formatted report."""
    separator = "=" * 60

    # --- Broken Links ---
    total_broken = sum(len(v) for v in repairs.values()) + sum(len(v) for v in unmatched.values())
    if total_broken > 0:
        print(f"\n{separator}")
        print(f"BROKEN LINKS")
        print(f"{separator}")

        for instance in sorted(set(list(repairs.keys()) + list(unmatched.keys()))):
            repaired = repairs.get(instance, [])
            no_match = unmatched.get(instance, [])
            count = len(repaired) + len(no_match)
            print(f"\n  {Colors.BOLD}{instance}{Colors.NC} ({count} broken):")

            for action in repaired:
                prefix = "REPAIR" if applied else "WOULD REPAIR"
                print(f"    {Colors.GREEN}[{prefix}]{Colors.NC} {action.title}")
                print(f"      Was: .../{Path(action.symlink_path).name}  ({Colors.RED}DEAD{Colors.NC})")
                print(f"      Now: .../{action.new_source.parent.name}/{action.new_source.name}")
                print(f"      Quality: {action.old_quality} -> {Colors.GREEN}{action.new_quality}{Colors.NC}")

            for broken in no_match:
                label = f"{broken.title}"
                if broken.year:
                    label += f" ({broken.year})"
                if broken.season is not None:
                    label += f" S{broken.season:02d}E{broken.episode:02d}"
                if broken.is_nzbdav:
                    print(f"    {Colors.DIM}[NZBDAV]{Colors.NC} {label} -> will self-heal when rclone-nzbdav reconnects")
                else:
                    print(f"    {Colors.RED}[NO MATCH]{Colors.NC} {label} -> needs Decypharr")

    # --- Quality Upgrades ---
    total_upgrades = sum(len(v) for v in upgrades.values())
    if total_upgrades > 0:
        print(f"\n{separator}")
        print(f"QUALITY UPGRADES")
        print(f"{separator}")

        for instance in sorted(upgrades.keys()):
            actions = upgrades[instance]
            print(f"\n  {Colors.BOLD}{instance}{Colors.NC} ({len(actions)} upgrade{'s' if len(actions) != 1 else ''}):")

            for action in actions:
                prefix = "UPGRADE" if applied else "WOULD UPGRADE"
                print(f"    {Colors.CYAN}[{prefix}]{Colors.NC} {action.title}: "
                      f"{action.old_quality} -> {Colors.GREEN}{action.new_quality}{Colors.NC} "
                      f"(+{action.quality_delta})")

    # --- Summary ---
    total_repaired = sum(len(v) for v in repairs.values())
    total_unmatched_all = sum(len(v) for v in unmatched.values())
    total_nzbdav_pending = sum(1 for bl in unmatched.values() for b in bl if b.is_nzbdav)
    total_unmatched = total_unmatched_all - total_nzbdav_pending
    total_upgrade_actions = sum(len(v) for v in upgrades.values())

    print(f"\n{separator}")
    print(f"SUMMARY")
    print(f"{separator}")
    verb_repair = "repaired" if applied else "repairable"
    verb_upgrade = "applied" if applied else "available"
    unmatched_detail = f"{total_unmatched} unmatched (need Decypharr)"
    if total_nzbdav_pending > 0:
        unmatched_detail += f" | {total_nzbdav_pending} NZBDav (self-healing)"
    print(f"  Broken:    {total_broken} found | {total_repaired} {verb_repair} | {unmatched_detail}")
    print(f"  Upgrades:  {total_upgrade_actions} found | {total_upgrade_actions} {verb_upgrade}")

    if total_unmatched > 0:
        print(f"\n  Unmatched (need Decypharr/re-search):")
        for instance, broken_list in sorted(unmatched.items()):
            for broken in broken_list:
                if broken.is_nzbdav:
                    continue
                label = broken.title
                if broken.year:
                    label += f" ({broken.year})"
                if broken.season is not None:
                    label += f" S{broken.season:02d}E{broken.episode:02d}"
                print(f"    - {label} [{broken.instance}]")

    if total_nzbdav_pending > 0:
        print(f"\n  NZBDav (will self-heal when rclone-nzbdav reconnects):")
        for instance, broken_list in sorted(unmatched.items()):
            for broken in broken_list:
                if not broken.is_nzbdav:
                    continue
                label = broken.title
                if broken.year:
                    label += f" ({broken.year})"
                if broken.season is not None:
                    label += f" S{broken.season:02d}E{broken.episode:02d}"
                print(f"    - {label} [{broken.instance}]")

    print()


def export_json(
    repairs: Dict[str, List[RepairAction]],
    unmatched: Dict[str, List[BrokenLink]],
    upgrades: Dict[str, List[RepairAction]],
    output_path: str,
):
    """Export results as JSON."""
    data = {
        "timestamp": datetime.now().isoformat(),
        "repairs": {},
        "unmatched": {},
        "upgrades": {},
        "summary": {},
    }

    for instance, actions in repairs.items():
        data["repairs"][instance] = [
            {
                "title": a.title,
                "symlink": str(a.symlink_path),
                "new_source": str(a.new_source),
                "old_quality": a.old_quality,
                "new_quality": a.new_quality,
                "quality_delta": a.quality_delta,
            }
            for a in actions
        ]

    for instance, broken_list in unmatched.items():
        data["unmatched"][instance] = [
            {
                "title": b.title,
                "year": b.year,
                "season": b.season,
                "episode": b.episode,
                "original_target": b.original_target,
                "quality_was": b.current_quality_summary,
                "source": "nzbdav" if b.is_nzbdav else "zurg/torbox",
            }
            for b in broken_list
        ]

    for instance, actions in upgrades.items():
        data["upgrades"][instance] = [
            {
                "title": a.title,
                "symlink": str(a.symlink_path),
                "new_source": str(a.new_source),
                "old_quality": a.old_quality,
                "new_quality": a.new_quality,
                "quality_delta": a.quality_delta,
            }
            for a in actions
        ]

    nzbdav_pending = sum(1 for bl in unmatched.values() for b in bl if b.is_nzbdav)
    data["summary"] = {
        "total_broken": sum(len(v) for v in repairs.values()) + sum(len(v) for v in unmatched.values()),
        "total_repaired": sum(len(v) for v in repairs.values()),
        "total_unmatched": sum(len(v) for v in unmatched.values()) - nzbdav_pending,
        "total_nzbdav_pending": nzbdav_pending,
        "total_upgrades": sum(len(v) for v in upgrades.values()),
    }

    with open(output_path, 'w') as f:
        json.dump(data, f, indent=2)
    log_success(f"Report exported to {output_path}")


# =============================================================================
# CLI
# =============================================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Repair broken symlinks and find quality upgrades in *arr libraries",
    )
    parser.add_argument("--apply", action="store_true",
                        help="Execute changes (default: dry-run)")
    parser.add_argument("--repair-only", action="store_true",
                        help="Only repair broken links")
    parser.add_argument("--upgrades-only", action="store_true",
                        help="Only find quality upgrades")
    parser.add_argument("--app", choices=["radarr", "sonarr", "all"], default="all",
                        help="Filter by app type (default: all)")
    parser.add_argument("--instance", type=str, default=None,
                        help="Specific instance (e.g. radarr-4k)")
    parser.add_argument("--upgrade-threshold", type=int, default=UPGRADE_THRESHOLD,
                        help=f"Minimum score delta for upgrades (default: {UPGRADE_THRESHOLD})")
    parser.add_argument("--refresh", action="store_true",
                        help="Trigger *arr rescan after apply")
    parser.add_argument("--research", action="store_true",
                        help="Trigger *arr search for unmatched broken links")
    parser.add_argument("--export", type=str, default=None, metavar="FILE",
                        help="Export results as JSON")
    parser.add_argument("--debug", action="store_true",
                        help="Verbose matching output")
    return parser.parse_args()


# =============================================================================
# Main
# =============================================================================

def main():
    args = parse_args()

    if args.repair_only and args.upgrades_only:
        log_error("Cannot use --repair-only and --upgrades-only together")
        sys.exit(1)

    check_repairs = not args.upgrades_only
    check_upgrades = not args.repair_only

    # Filter library folders
    folders_to_scan: Dict[str, Tuple[str, str, List[str]]] = {}
    for folder_name, (instance, content_type, zurg_folders) in LIBRARY_FOLDERS.items():
        if args.instance and instance != args.instance:
            continue
        if args.app == "radarr" and content_type != "movie":
            continue
        if args.app == "sonarr" and content_type != "series":
            continue
        folders_to_scan[folder_name] = (instance, content_type, zurg_folders)

    if not folders_to_scan:
        log_error("No library folders match the specified filters")
        sys.exit(1)

    # Determine which zurg folders to scan
    need_movie_folders = set()
    need_series_folders = set()
    for folder_name, (instance, content_type, zurg_folders) in folders_to_scan.items():
        for zf in zurg_folders:
            if content_type == "movie":
                need_movie_folders.add(zf)
            else:
                need_series_folders.add(zf)

    mode = "DRY-RUN" if not args.apply else "APPLY"
    log(f"Media Repair Links [{mode}]")

    # === Mount health preflight ===
    # Abort if critical FUSE mounts are not healthy — running with dead mounts
    # causes false broken-symlink detection and incorrect *arr state changes.
    # NOTE: Directory listing alone is NOT sufficient — Real-Debrid bandwidth
    # limits allow dir listing but cause I/O errors on file access, which makes
    # valid symlinks appear broken. We must verify actual file readability.
    REQUIRED_MOUNTS = [
        (SYMLINKS_BASE, "symlinks library"),
        (ZURG_BASE / "__all__", "zurg"),
    ]
    OPTIONAL_MOUNTS = OPTIONAL_MOUNTS_CFG
    mount_ok = True
    for mount_path, label in REQUIRED_MOUNTS:
        if not mount_path.is_dir():
            log_error(f"MOUNT CHECK FAILED: {mount_path} ({label}) is not accessible — aborting")
            mount_ok = False
        else:
            try:
                list(mount_path.iterdir())
            except OSError as e:
                log_error(f"MOUNT CHECK FAILED: {mount_path} ({label}) I/O error: {e} — aborting")
                mount_ok = False

    # Deep health check: verify zurg can actually serve file content, not just
    # directory listings. Real-Debrid bandwidth limits allow listing but return
    # I/O errors on file stat/read — without this check that causes mass
    # false-positive broken-link detection and deletion of valid symlinks.
    if mount_ok:
        zurg_all = ZURG_BASE / "__all__"
        sample_ok = False
        try:
            for entry in os.scandir(zurg_all):
                if not entry.is_dir(follow_symlinks=False):
                    continue
                # Try to stat a media file inside the first directory
                try:
                    for sub in os.scandir(entry.path):
                        if Path(sub.name).suffix.lower() in MEDIA_EXTENSIONS:
                            sub.stat()  # follows symlinks, triggers actual file access
                            sample_ok = True
                            break
                except OSError as e:
                    log_error(f"MOUNT CHECK FAILED: zurg file access test returned I/O error: {e}")
                    log_error("This typically means Real-Debrid bandwidth limit is active.")
                    log_error("Aborting to prevent false broken-link detection.")
                    mount_ok = False
                    break
                if sample_ok or not mount_ok:
                    break
        except OSError as e:
            log_error(f"MOUNT CHECK FAILED: zurg scan error: {e}")
            mount_ok = False

        if mount_ok and not sample_ok:
            log_warn("MOUNT CHECK: Could not find a sample media file in zurg to verify readability")

    if not mount_ok:
        log_error("One or more required mounts are down. Refusing to run to prevent false broken-link detection.")
        sys.exit(1)
    for mount_path, label in OPTIONAL_MOUNTS:
        if not mount_path.is_dir():
            log_warn(f"MOUNT CHECK: {mount_path} ({label}) is not accessible — NZBDav items may appear broken")
        else:
            try:
                list(mount_path.iterdir())
            except OSError:
                log_warn(f"MOUNT CHECK: {mount_path} ({label}) has I/O errors — NZBDav items may appear broken")

    log(f"Scanning: {', '.join(sorted(folders_to_scan.keys()))}")
    if args.upgrade_threshold != UPGRADE_THRESHOLD:
        log(f"Upgrade threshold: {args.upgrade_threshold}")
    print()

    # Phase 1: Scan library for broken links and upgrade candidates
    log(f"Phase 1: Scanning library folders...")
    all_broken: List[BrokenLink] = []
    all_candidates: List[UpgradeCandidate] = []

    for folder_name, (instance, content_type, zurg_folders) in folders_to_scan.items():
        broken, candidates = scan_library_folder(
            folder_name, instance, content_type,
            check_upgrades=check_upgrades,
            debug=args.debug,
        )
        all_broken.extend(broken)
        all_candidates.extend(candidates)
        if broken or candidates:
            log(f"  {folder_name}: {len(broken)} broken, {len(candidates)} upgrade candidates")

    log_success(f"Found {len(all_broken)} broken links, {len(all_candidates)} upgrade candidates")

    if not all_broken and not all_candidates:
        log_success("Library is clean — no broken links or upgrades found")
        return

    # Phase 2: Build media indexes
    log(f"\nPhase 2: Building zurg index...")
    zurg_index = MediaIndex(verbose=args.debug)

    if need_movie_folders:
        zurg_index.scan_movies(list(need_movie_folders))
    if need_series_folders:
        zurg_index.scan_series(list(need_series_folders))

    # Build torbox index if mount is available (disabled — out of scope)
    torbox_index = None
    # if TORBOX_BASE.exists() and (TORBOX_BASE / "__all__").exists():
    #     log(f"Torbox mount detected at {TORBOX_BASE}")
    #     torbox_index = MediaIndex(verbose=args.debug, base_path=TORBOX_BASE)
    #     if need_movie_folders:
    #         torbox_index.scan_movies(["__all__"])
    #     if need_series_folders:
    #         torbox_index.scan_series(["__all__"])

    # Phase 3: Match broken links to media content
    repairs: Dict[str, List[RepairAction]] = defaultdict(list)
    unmatched: Dict[str, List[BrokenLink]] = defaultdict(list)
    upgrade_actions: Dict[str, List[RepairAction]] = defaultdict(list)

    if check_repairs and all_broken:
        log(f"\nPhase 3: Matching broken links...")
        for i, broken in enumerate(all_broken):
            log_progress(i + 1, len(all_broken), broken.title[:50])
            _, _, zurg_folders = LIBRARY_FOLDERS[broken.library_folder]
            action = _find_best_replacement(broken, zurg_index, torbox_index, zurg_folders, debug=args.debug)
            if action:
                repairs[broken.instance].append(action)
            else:
                unmatched[broken.instance].append(broken)
        print()  # Clear progress line

    if check_upgrades and all_candidates:
        phase = "4" if check_repairs else "3"
        log(f"\nPhase {phase}: Finding quality upgrades...")
        for i, candidate in enumerate(all_candidates):
            log_progress(i + 1, len(all_candidates), candidate.title[:50])
            _, _, zurg_folders = LIBRARY_FOLDERS[candidate.library_folder]
            action = _find_best_upgrade(
                candidate, zurg_index, torbox_index, zurg_folders,
                threshold=args.upgrade_threshold,
                debug=args.debug,
            )
            if action:
                upgrade_actions[candidate.instance].append(action)
        print()  # Clear progress line

    # Phase 4: Apply changes
    all_applied: List[RepairAction] = []

    if args.apply:
        all_actions = []
        for actions in repairs.values():
            all_actions.extend(actions)
        for actions in upgrade_actions.values():
            all_actions.extend(actions)

        if all_actions:
            log(f"\nApplying {len(all_actions)} changes...")
            success = 0
            for action in all_actions:
                # Validate source still exists
                if not action.new_source.exists():
                    log_warn(f"  Source gone: {action.new_source}")
                    continue

                if atomic_relink(action.symlink_path, action.new_source):
                    all_applied.append(action)
                    success += 1
                    label = "REPAIRED" if action.action_type == "repair" else "UPGRADED"
                    log_success(f"  [{label}] {action.title}: {action.old_quality} -> {action.new_quality}")
                else:
                    log_error(f"  Failed: {action.title}")

            log_success(f"Applied {success}/{len(all_actions)} changes")

            # Refresh *arr if requested
            if args.refresh and all_applied:
                log(f"\nRefreshing *arr instances...")
                refresh_arr_items(all_applied, debug=args.debug)

    # Remove unmatched broken symlinks and re-search
    if args.apply and unmatched:
        total_unmatched = sum(len(v) for v in unmatched.values())
        log(f"\nRemoving {total_unmatched} unmatched broken symlinks...")
        removed = 0
        for instance, broken_list in unmatched.items():
            for broken in broken_list:
                try:
                    broken.symlink_path.unlink()
                    removed += 1
                except OSError as e:
                    log_error(f"  Failed to remove {broken.symlink_path}: {e}")
        log_success(f"Removed {removed}/{total_unmatched} broken symlinks")

    if args.research and unmatched:
        log(f"\nRe-searching unmatched broken links in *arr...")
        research_unmatched(unmatched, debug=args.debug)

    # Report
    print_report(repairs, unmatched, upgrade_actions, applied=args.apply)

    # JSON export
    if args.export:
        export_json(repairs, unmatched, upgrade_actions, args.export)


if __name__ == "__main__":
    main()
