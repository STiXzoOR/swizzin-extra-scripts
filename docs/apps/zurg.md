# Zurg (debrid + Usenet)

WebDAV server that presents Real-Debrid, TorBox, AllDebrid and Usenet content as a filesystem, mounted via rclone.

Zurg ships in two builds, and the installer asks which one you have:

| Build  | Repo                                | Notes                                                          |
| ------ | ----------------------------------- | -------------------------------------------------------------- |
| `paid` | `debridmediamanager/zurg` (private) | GitHub sponsors. Manages its own rclone mount. Multi-account.   |
| `free` | `debridmediamanager/zurg-testing`   | Public. Real-Debrid only, single `token:`. Separate mount unit. |

The build is recorded in swizdb (`zurg/version`) and recovered from `config.yml` (`rclone_enabled: true` means paid) if that entry is missing.

## Services

| Service               | Purpose                     | Which build           |
| --------------------- | --------------------------- | --------------------- |
| `zurg.service`        | The WebDAV server           | both                  |
| `rclone-zurg.service` | The rclone filesystem mount | **free only**         |

The paid build manages rclone itself via `rclone_enabled: true` + `mount_path:`, so it has no separate mount unit.

## Port

Fixed at 9999 (WebDAV server default), bound to `127.0.0.1`.

## Key Files

| Path                                  | Purpose                                            |
| ------------------------------------- | -------------------------------------------------- |
| `/usr/bin/zurg`                       | Binary                                              |
| `~/.config/zurg/config.yml`           | Configuration (mode 600 — holds API tokens)         |
| `~/.config/zurg/nzbs/`                | Drop `.nzb` files here (Usenet provider only)       |
| `~/.config/zurg/data/`                | Torrent cache, Plex snapshots                       |
| `~/.config/zurg/data/local/`          | Local files overlaid onto the mount (see below)     |
| `~/.config/zurg/logs/`                | `zurg.log` and `rclone.log`                         |
| `/mnt/zurg/`                          | rclone mount point                                  |
| `~/.config/rclone/rclone.conf`        | rclone remote (**free build only**)                 |

## The mount is a union, not a plain WebDAV mount

The paid build does not mount its WebDAV endpoint directly. It builds an rclone **union** of two upstreams, passed entirely through environment variables (there is no rclone.conf to read):

```
RCLONE_CONFIG_ZURG_TYPE=union
RCLONE_CONFIG_ZURG_UPSTREAMS=<configdir>/data/local :webdav:
```

So the mount root is `data/local/` merged over what zurg serves. That local upstream exists for files zurg has no concept of — subtitles, posters, local media.

The consequence worth knowing: **every subdirectory of `data/local/` appears at the mount root**, whether or not it corresponds to a configured directory. One that matches nothing shows up as a permanently empty folder, and every lookup of it makes zurg log:

```
ERROR router Error handling group directory <name>: cannot find directory <name>
```

This is easy to miss — the folder looks like a harmless empty directory, and the errors only fire when something happens to stat it. `bash zurg.sh --update` now reports orphaned overlay directories. To clear one by hand:

```bash
rmdir ~/.config/zurg/data/local/<name>          # only succeeds if truly empty
# then drop it from the mount's dir cache (see rc-addr in the rclone args)
curl -X POST 127.0.0.1:<rc-port>/vfs/forget -H 'Content-Type: application/json' -d '{"dir":"<name>"}'
```

Forgetting the **entry itself** is what removes it; forgetting the root (`{"dir":""}`) is not enough, because the VFS caches the child directory node separately. The mount runs with `--dir-cache-time 12h --poll-interval 0`, so without the `vfs/forget` the phantom persists for up to 12 hours.

Verify with `curl -s -X POST 127.0.0.1:<rc-port>/operations/list -d '{"fs":"zurg:","remote":"","opt":{"dirsOnly":true}}'`, which shows rclone's real view independent of the kernel cache.

`~` is the zurg owner's home, from swizdb `zurg/owner`.

## Accounts (`providers:`)

The paid build takes any number of accounts in one `providers:` list — Real-Debrid, TorBox, AllDebrid and Usenet side by side, or several accounts on one service:

```yaml
providers:
  - type: realdebrid
    token: "RD_API_TOKEN"
    download_tokens:            # rotated to when the daily bandwidth cap is hit
      - "ANOTHER_RD_TOKEN"
  - type: torbox
    token: "TORBOX_API_KEY"
  - type: alldebrid
    token: "ALLDEBRID_API_KEY"
  - type: nzb                   # Usenet: not a debrid service
    nntp:
      host: "news.example.com"
      port: 563
      tls: true
      username: "user"
      password: "pass"
      connections: 8            # set to your plan's real allowance
```

Useful per-entry keys: `name` (defaults to `type`; required when two entries share a type), `disabled: true`, and `watchlist: true` (at most one entry, never `nzb`).

A release held by several accounts is one library entry with a copy per account, so a second account is redundancy rather than duplication — reads fail over to the next healthy copy instead of triggering repair.

### Supplying accounts non-interactively

| Variable                                                                                   | Purpose               |
| ------------------------------------------------------------------------------------------ | --------------------- |
| `RD_TOKEN`                                                                                 | Real-Debrid           |
| `TORBOX_TOKEN`                                                                             | TorBox                |
| `ALLDEBRID_TOKEN`                                                                          | AllDebrid             |
| `ZURG_NNTP_HOST` / `_PORT` / `_TLS` / `_USER` / `_PASS` / `_CONNECTIONS`                    | Usenet                |

`_PORT` defaults to 563 with TLS and 119 without. At least one account is required. If no `RD_TOKEN` is configured the Decypharr integration is skipped, since Decypharr is Real-Debrid specific.

## Per-account directories

Every configured account gets its own directory at the mount root — `__realdebrid__`, `__torbox__`, `__alldebrid__`, `__nzb__` — created from the `providers:` block, not from `directories:`. They appear even on a single-account install and cannot be suppressed by filters.

These directories **pin reads to that account**: `__torbox__/X/movie.mkv` streams from TorBox and fails if TorBox cannot serve it, rather than silently falling back. Reads elsewhere in the mount still fail over normally. `__all__` and your own `directories:` are unaffected.

This matters for consumers pointed at a specific path — Decypharr uses `/mnt/zurg/__all__/`, which keeps failover.

## Migrating a pre-providers config

Configs written before multi-account support used top-level `token:`, `download_tokens:` and `strm_link_token:`. They still load — read as a single Real-Debrid account, with a deprecation warning at startup — but new account features are only reachable from a `providers:` block.

```bash
bash zurg.sh --migrate-providers
```

This rewrites the three keys into a `providers:` entry in place, line by line so the hand-written `directories:` filters and comments survive untouched, and saves a timestamped `config.yml.pre-providers.<ts>` next to the config. It is idempotent, and refuses to run on the free build (which has no `providers:` support). Set `ZURG_MIGRATE_RESTART=true|false` to skip the restart prompt.

`bash zurg.sh --update` prints a hint when it finds an unmigrated config.

## Updating

```bash
bash zurg.sh --update                 # binary only, latest stable release
bash zurg.sh --update --latest        # newest release including nightlies
bash zurg.sh --update --full          # full reinstall (rewrites config.yml)
ZURG_VERSION_TAG=2026.08.17.0150-nightly bash zurg.sh --update
```

The paid build needs GitHub auth for the private repo: `GITHUB_TOKEN`, an authenticated `gh` CLI, or an interactive prompt.

> `--update --full` **rewrites `config.yml` from the template**, discarding hand-written `directories:` filters. Use plain `--update` to change only the binary.

## Gotchas

- **Restarting zurg cycles the mount.** Anything mid-scan can see the library briefly vanish. With Plex, set `plex_database_path` so zurg snapshots the database before touching the mount; that feature is Plex-only and needs Plex on the same host.
- **`get_downloads_limit: 0` means "cache nothing"**, not "no limit" — `-1` (or omitting the key) is unlimited. A `0` carried over from an old config silently empties `__downloads__`.
- **D-state readers wedge the unmount.** Processes stuck in uninterruptible sleep on the FUSE mount (typically arr `ffprobe`) survive kills and can leave `Transport endpoint is not connected` on restart. Recover with `fusermount -uz /mnt/zurg` then restart zurg.
- **An empty folder at the mount root is not cosmetic.** It means an orphaned `data/local/` overlay directory — see the union section above. Renaming a directory in `config.yml` (e.g. `shows` → `series`) without renaming its `data/local/` counterpart is how these are created.
- **Upgrading re-imports the cache once.** Torrents cached in the pre-provider format have no provider stamp and are re-imported on the next refresh; archive releases re-match once.
- The free build has no `providers:` support — switch with `--switch-version paid` first.

## No Nginx

Zurg has an nginx config (`/etc/nginx/apps/zurg.conf`) behind basic auth, but no base-URL support, so the location block rewrites URLs with `sub_filter`. It is otherwise an internal service consumed directly by Plex/Emby, the arrs and Decypharr.

## Related Scripts

- `decypharr.sh` — qBittorrent-compatible debrid client; reads `/mnt/zurg/__all__/`
- `arr-symlink-import.sh` — creates symlinks from the zurg mount to arr root folders
