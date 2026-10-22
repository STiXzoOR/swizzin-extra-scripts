# arr-tools

Maintenance tools for a Sonarr/Radarr library built from debrid (zurg, TorBox) and Usenet (nzbdav) mounts with symlinked library folders.

All site-specific layout (mount roots, which *arr instances exist, which library folders they own, nzbdav categories) is read from one JSON file kept outside git:

```
$MEDIA_TOOLS_CONFIG   (default /opt/swizzin-extras/media-tools.json)
```

Start from [`configs/media-tools.json.example`](../configs/media-tools.json.example). Without the file the tools assume a single Radarr and Sonarr with `movies`/`series` folders under `/mnt/symlinks`.

| Tool | What it does |
| ---- | ------------ |
| `media_common.py` | Shared library: config loading, *arr API client, release quality scoring, title/year parsing, mount indexing. Imported by the others. |
| `media-library-sync.py` | Indexes the debrid mounts and syncs them against the *arr libraries. |
| `media-repair-links.py` | Finds broken library symlinks (removed torrents, mount reshuffles) and re-points them at matching content still on the mounts, and finds same-tier quality upgrades. Dry-run by default; `--apply` to change, `--refresh` to rescan the *arr afterwards. Refuses to run when the mounts fail a real read check. |
| `nzbdav-decay-check.py` | Samples segments across each nzbdav-backed file and STATs them on every enabled Usenet provider, flagging files whose articles have decayed to one provider (`RISK`), gaps (`HOLES`) or none (`DEAD`). |
| `nzbdav-decay-cron.sh` | Weekly wrapper for the decay check: logs, keeps a JSON report and notifies only when something is actionable. |

API keys for TMDB/TVDB lookups come from the `TMDB_API_KEY` / `TVDB_API_KEY` environment variables; *arr keys are read from each instance's `config.xml`.
