# Docker Apps

Docker Compose apps wrapped by systemd for lifecycle management.

## Autopulse

Media server library notifier. Receives Sonarr/Radarr webhooks and sends targeted library update notifications to Emby/Jellyfin/Plex via path-specific API calls (replaces slow full-library scans).

**Install:** `bash autopulse.sh`
**Update:** `bash autopulse.sh --update`
**Remove:** `bash autopulse.sh --remove`

**Auto-discovery:** The installer automatically discovers all Sonarr/Radarr/Lidarr/Readarr instances and Emby/Jellyfin/Plex servers. It configures Autopulse triggers/targets and adds webhook notifications to each arr instance.

**Ports:** Two dynamic ports (API + UI) allocated from 10000-12000 range.

**Nginx:** Exposed at `/autopulse` subfolder. Trigger API endpoints at `/autopulse/triggers/` bypass basic auth for Sonarr/Radarr webhook access.

**Environment overrides** (unattended install):
- `AUTOPULSE_PORT` — API port
- `AUTOPULSE_UI_PORT` — UI port
- `AUTOPULSE_AUTH_PASSWORD` — Auth password

**Upstream:** [dan-online/autopulse](https://github.com/dan-online/autopulse)

---

## Lingarr

Subtitle translation service that auto-discovers Sonarr/Radarr installations.

### File Layout

| Path                                  | Purpose                    |
| ------------------------------------- | -------------------------- |
| `/opt/lingarr/docker-compose.yml`     | Compose file               |
| `/opt/lingarr/config/`                | Lingarr config + SQLite DB |
| `/etc/nginx/apps/lingarr.conf`        | Reverse proxy (subfolder)  |
| `/etc/nginx/sites-available/lingarr`  | Reverse proxy (subdomain)  |
| `/etc/systemd/system/lingarr.service` | Systemd wrapper            |
| `/install/.lingarr.lock`              | Swizzin lock file          |

### Features

- Docker Engine + Compose plugin auto-installed if missing
- Media paths auto-discovered from Sonarr/Radarr SQLite databases (base + multi-instance)
- Sonarr/Radarr API credentials auto-discovered from `config.xml`
- Port bound to `127.0.0.1` only (nginx handles external access)
- Container runs as master user UID:GID
- `--update` flag pulls latest image and recreates container
- Supports subfolder mode (`/lingarr/` with sub_filter) and subdomain mode

### Subdomain Mode

Subdomain mode follows the same pattern as seerr.sh:

- Standalone panel meta class
- Let's Encrypt certificate
- Organizr integration (optional)

---

## LibreTranslate

Machine translation API with GPU auto-detection and Lingarr integration.

### File Layout

| Path                                         | Purpose                   |
| -------------------------------------------- | ------------------------- |
| `/opt/libretranslate/docker-compose.yml`     | Compose file              |
| `/opt/libretranslate/config/`                | DB + models cache         |
| `/etc/nginx/apps/libretranslate.conf`        | Reverse proxy (subfolder) |
| `/etc/nginx/sites-available/libretranslate`  | Reverse proxy (subdomain) |
| `/etc/systemd/system/libretranslate.service` | Systemd wrapper           |
| `/install/.libretranslate.lock`              | Swizzin lock file         |

### Features

- Auto-detects NVIDIA GPU and uses CUDA image if available
- Whiptail multi-select picker for 48 supported languages
- Auto-configures Lingarr integration if Lingarr is detected
- Native `LT_URL_PREFIX` support for subfolder mode (no sub_filter needed)
- Port dynamically allocated via `port 10000 12000`
- htpasswd protection on web UI, API endpoints bypass auth

---

## StremThru

Debrid streaming proxy with store management. Provides Torznab API for Prowlarr integration.

### File Layout

| Path                                   | Purpose                   |
| -------------------------------------- | ------------------------- |
| `/opt/stremthru/docker-compose.yml`    | Compose file              |
| `/opt/stremthru/data/`                 | SQLite DB + hashlists     |
| `/opt/stremthru/.env`                  | Credentials               |
| `/etc/nginx/apps/stremthru.conf`       | Reverse proxy (subfolder) |
| `/etc/systemd/system/stremthru.service`| Systemd wrapper           |
| `/install/.stremthru.lock`             | Swizzin lock file         |

### Features

- Single container with SQLite database
- Stores debrid credentials in `.env` file (chmod 600)
- `proxy_cookie_path` for session cookie rewriting behind subfolder proxy
- Torznab API endpoint bypasses auth for Prowlarr access

---

## MediaFusion

Stremio/Kodi universal add-on with native Torznab API for Prowlarr. 5-container stack (v6, Rust).

### File Layout

| Path                                      | Purpose                      |
| ----------------------------------------- | ---------------------------- |
| `/opt/mediafusion/docker-compose.yml`     | Compose file (5 services)    |
| `/opt/mediafusion/pgdata/`               | PostgreSQL data              |
| `/opt/mediafusion/redis/`                | Redis persistence            |
| `/etc/nginx/apps/mediafusion.conf`       | Reverse proxy (subfolder)    |
| `/etc/systemd/system/mediafusion.service`| Systemd wrapper              |
| `/install/.mediafusion.lock`             | Swizzin lock file            |

### Features

- 5 containers: app, worker, PostgreSQL, Redis, TRAWL (browser pool)
- Pinned to `mhdzumair/mediafusion:6.1.6` — the Rust rewrite. Do not track `:latest`.
- API port comes from `STREAM_RS_PORT`; the worker runs `/usr/local/bin/mediafusion-worker`
- `HOST_URL` / `POSTER_HOST_URL` set from the Organizr domain detection chain
- `sub_filter` rules rewrite SPA paths, including **backtick/template-literal**
  variants (`` `/api/v1${...} ``) that the v6 React bundle emits
- Custom Prowlarr Cardigann indexer definition deployed from `resources/prowlarr/mediafusion.yml`
- Torznab and manifest endpoints bypass auth for Prowlarr/Stremio access

### Upgrading from v5 (Python) to v6 (Rust)

There is **no in-place migration**. v6 recognises Alembic revision `d826df80371b`;
any other revision makes it replay every sqlx migration, and because Postgres
`CREATE TYPE ... AS ENUM` has no `IF NOT EXISTS` guard it aborts with
`type "contributionstatus" already exists` (SQLSTATE 42710) and crash-loops.
A failed attempt commits nothing, so it is safe to try and roll back.

Upgrade by pointing `POSTGRES_URI` at a **new, empty database** and letting
migrations build the schema from scratch. Keep the old database until the new
one is populated — that is the rollback path.

TRAWL (`ghcr.io/germondai/trawl`) replaces Browserless. A plain FlareSolverr —
Byparr included — is **not** sufficient: it solves the challenge, but lacks
TRAWL's session API, so AJAX magnet extraction fails with
`{"success":false,"error":"Invalid session"}`. TRAWL shares the stack's Redis on
database 1 (MediaFusion itself uses database 0).

---

## Zilean

DMM hashlist Torznab indexer. Indexes debrid-cached content from DebridMediaManager hashlists.

### File Layout

| Path                                  | Purpose                   |
| ------------------------------------- | ------------------------- |
| `/opt/zilean/docker-compose.yml`      | Compose file              |
| `/opt/zilean/data/`                   | Config + IMDB title data  |
| `/opt/zilean/pgdata/`                | PostgreSQL data           |
| `/etc/nginx/apps/zilean.conf`        | Reverse proxy (subfolder) |
| `/etc/systemd/system/zilean.service` | Systemd wrapper           |
| `/install/.zilean.lock`              | Swizzin lock file         |

### Features

- 2 containers: app + PostgreSQL
- Standard Torznab API compatible with Prowlarr Generic Torznab indexer
- IMDB title data auto-downloaded on first run

---

## NzbDAV

NZB-to-WebDAV bridge for using debrid services as download clients in arr apps.

### File Layout

| Path                                | Purpose                   |
| ----------------------------------- | ------------------------- |
| `/opt/nzbdav/docker-compose.yml`   | Compose file              |
| `/opt/nzbdav/config/`             | SQLite DB + config        |
| `/etc/nginx/apps/nzbdav.conf`     | Reverse proxy (subfolder) |
| `/etc/systemd/system/nzbdav.service` | Systemd wrapper        |
| `/install/.nzbdav.lock`           | Swizzin lock file         |

### Features

- Single container with SQLite database
- React Router SSR frontend with `sub_filter` path rewriting
- Bridges NZB protocol to WebDAV for debrid download clients

---

## Remux

Jellyfin-compatible media server ([lostb1t/remux](https://github.com/lostb1t/remux), Rust). Aggregates content from Stremio addons, local files, WebDAV servers, and torrents; ships with jellyfin-ffmpeg for transcoding. Works with any Jellyfin client (Infuse, Swiftfin, Jellyfin apps).

**Install:** `REMUX_DOMAIN=remux.example.com bash remux.sh`
**Update:** `bash remux.sh --update` (add `--latest` to switch to the `:nightly` channel)
**Remove:** `bash remux.sh --remove`
**Add MDBList catalogs:** `REMUX_MDBLIST_APIKEY=<key> bash remux.sh --add-mdblist <listId>[,<listId>...]`

### File Layout

| Path                                | Purpose                                     |
| ----------------------------------- | ------------------------------------------- |
| `/opt/remux/docker-compose.yml`     | Compose file (recreated by installer)       |
| `/opt/remux/data/`                  | All state: SQLite DB, config, logs, caches  |
| `/opt/remux-mdblist/app/`           | MDBList→Stremio catalog sidecar source + deps |
| `/etc/nginx/sites-available/remux`  | Subdomain vhost                             |
| `/etc/systemd/system/remux.service` | Systemd wrapper (starts both containers)    |
| `/install/.remux.lock`              | Swizzin lock file                           |

### Features

- **Subdomain-only** — Jellyfin-compatible clients need a clean root URL and Remux has no base-path support. Vhost mirrors emby.sh: WebSocket map, streaming timeouts (1h), `proxy_buffering off`, Range passthrough. No nginx basic auth — Remux has its own user management.
- Runs as the app owner's uid:gid with `HOME=/data` (the bundled rqbit torrent engine aborts without a writable `$HOME/.cache`; everything else is baked to write under `/data`).
- `/mnt` mounted read-only with `rslave` so `/mnt/symlinks` and the FUSE-backed rclone mounts it points into (zurg, nzbdav) resolve in-container and survive host remounts.
- Release channels: `:latest` (stable, default) / `:nightly` via `--latest`, persisted in swizdb like aiostreams.
- Healthcheck against the container's `/health` endpoint (returns 200 unauthenticated).
- Admin dashboard at `/dashboard`; WebDAV/Stremio sources are configured there.

### Library: MDBList catalogs, not local scanning

Remux's `opendal-local` addon **cannot** index a debrid symlink farm. Video files under `/mnt/symlinks` are symlinks (into zurg/nzbdav); opendal's fs lister reports symlinks as non-`FILE` entries and skips them, so only `.srt` sidecars get indexed. There is no follow-symlinks option.

Instead, the installer ships an **MDBList → Stremio catalog sidecar** (`jaruba/stremio-mdblist`, pinned commit, `node:20-alpine`):

- Defined as a second `mdblist` service in `docker-compose.yml`, always regenerated by `_write_compose` so it survives `--update` and reinstall. Source + prod deps staged under `/opt/remux-mdblist/app` and mounted read-only.
- Reachable **only** on the compose network at `http://mdblist:64321` — never host-published. Manifest route: `/{listId}/{apikey}/manifest.json` (the public baby-beamup instance 500s; self-hosting is required).
- Disable with `REMUX_MDBLIST=false`.
- `--add-mdblist <ids>` registers each MDBList list as a Remux catalog addon (priority 50), enables its catalogs for import, and triggers a refresh. List IDs and `REMUX_MDBLIST_APIKEY` are runtime inputs (never stored in the script); the key is passed to `curl` via 600-perm config files so it never appears in `ps`. Needs the admin account created + signed in once (reads the session token from `data/db.sqlite`).
- Playback of catalog titles resolves through your Stremio stream addon (e.g. AIOStreams), same debrid backend as Emby.

---

## Bazarr+

[Bazarr+](https://github.com/LavX/bazarr) is a hard fork of Bazarr (`ghcr.io/lavx/bazarr`; tags have no `v` prefix). One install handles any number of Sonarr/Radarr instances and refreshes Emby, Silo, Jellyfin and Plex after a subtitle lands.

### File Layout

| Path | Purpose |
| ---- | ------- |
| `/opt/bazarrplus/config/` | `/config` in the container: `config/config.yaml`, `db/bazarr.db`, `provider_hub/` plugins |
| `/opt/bazarrplus/overlays/` | Provider overlays, bind-mounted read-only over the image's copies |
| `/opt/bazarrplus/.migrated_from` | Migration record used by `--rollback` |
| `/opt/swizzin-extras/bazarrplus-backups/<timestamp>/` | Pre-migration tarballs of every Bazarr config directory |

### Migration from swizzin Bazarr

- Detects `bazarr` plus every `bazarr-<name>` unit (from its `--config` dir), stops them and tars each config dir before changing anything.
- Bazarr+ starts from a copy of the main config and database. On first boot the fork adopts upstream's schema (folds `table_*_subtitles` back, local-id PK cutover); the copy cannot be opened by upstream Bazarr afterwards.
- Each `bazarr-<name>` instance's Sonarr/Radarr is added as an extra instance named `Sonarr <NAME>`. Its own database (history, blacklist) is not merged.
- Old services are disabled, not removed. `--rollback` re-enables and starts them from their untouched config dirs. `BAZARRPLUS_MIGRATE=no` installs fresh instead.
- The API key keeps working, but Bazarr+ stores it encrypted (`enc:...`), so read it from the old config if you need it.

### Features

- Host networking: Sonarr/Radarr, media servers and Byparr stay on `127.0.0.1`. Listens on `127.0.0.1:<port>` under `/bazarrplus/`; protect it with `bash organizr.sh --configure`.
- Upstream's container hardening (read-only root, all capabilities dropped except CHOWN/SETUID/SETGID).
- `FLARESOLVERR_URL` is set when something listens on `:8191` (Byparr).
- `overlays/bazarr-plus/providers/` carries the Greek provider fixes (greeksubs Unicode Referer and fresh secCode, subs4series/subs4free Cloudflare clearance via Byparr), three-way merged onto the fork's own files.
- Provider Hub catalog plugins can replace a built-in of the same name, which would bypass the overlays: install only providers that are not built in.
- Settings validator gotcha: search/upgrade intervals only accept 6, 12, 24, 168 or 876000 (never). Any other value is silently reset to 6 hours.

## TRAWL

[TRAWL](https://github.com/germondai/trawl) (`ghcr.io/germondai/trawl`, `:baseline` on CPUs without AVX2) clears Cloudflare, Turnstile, Anubis and CAPTCHA walls. It serves the FlareSolverr API at `/v1`, so Prowlarr, Jackett and Bazarr need no change, and adds a native `/scrape` and browser-session API that MediaFusion v6's ext.to scraper requires (Byparr's sessions return `Invalid session`).

- Listens on `127.0.0.1:8191` (`TRAWL_PORT`). A running Byparr or FlareSolverr is stopped and disabled, not removed (`TRAWL_REPLACE=yes` skips the prompt); `--rollback` restarts it.
- Single process with an in-memory clearance cache (no Redis); `TRAWL_POOL_SIZE` warm browsers (default 3, about 300-400 MB each).
- Local metrics dashboard at `/dashboard`, history in `/opt/trawl/metrics/`.
- `mediafusion.sh` uses this shared TRAWL instead of its bundled sidecar when `/install/.trawl.lock` exists. The compose file is only written at install, so an existing MediaFusion needs `TRAWL_URL` changed and the `mediafusion-trawl` service removed by hand.

## ROMarr

*arr-style ROM download automation ([BlizzHacker/romarr](https://github.com/BlizzHacker/romarr), Python, MIT). It searches Prowlarr, hands releases to a download client, verifies them against No-Intro/Redump DATs, files them into RomM's `roms/{fs_slug}` and asks RomM to scan.

**Install:** `ROMARR_DOMAIN=romarr.example.com bash romarr.sh` (install `romm.sh` first so the library and RomM account get wired)
**Update:** `bash romarr.sh --update` (pinned image; bump with `ROMARR_VERSION=x.y.z`)
**Remove:** `bash romarr.sh --remove`
**Re-wire clients:** `bash romarr.sh --wire` | **Status:** `bash romarr.sh --status`

### File Layout

| Path                              | Purpose                                                       |
| --------------------------------- | ------------------------------------------------------------- |
| `/opt/romarr/.env`                | First-run settings, password (defaults to the swizzin master password, like the arrs), API key (600, root) |
| `/opt/romarr/config/romarr.json`  | All runtime state: settings, clients, history, queue          |
| `/opt/romarr/downloads/`          | Debrid staging (Real-Debrid files land here before import)    |
| `/opt/romm/.romarr_credentials`   | RomM account + non-expiring client token ROMarr uses (600, root) |
| `/etc/cron.d/romarr-recover`      | Stalled-import recovery every 5 min (`--recover-stalled`)     |
| `/etc/nginx/sites-available/romarr` | Subdomain vhost                                             |

### Wiring (auto-discovered, each optional)

| Integration | How |
| --- | --- |
| Prowlarr | URL + key from the owner's `config.xml` → `PROWLARR_*` env (first run) |
| nzbdav (usenet) | SABnzbd API; the installer adds a `romarr` category **live** via `update-config`, including `ensure-article-existence-categories` |
| Real-Debrid (torrent) | ROMarr's built-in RD client, added **first**; it can fetch uncached torrents. Token from `ROMARR_RD_API_TOKEN` or decypharr's config |
| decypharr (torrent) | qBittorrent API, added second as standby. Auth is decypharr's arr scheme: username = ROMarr's URL, password = its API key |
| RomM | A dedicated `romarr` RomM account (admin: RomM 5.x has only user/admin roles and scans need `tasks.run`) |

ROMarr sends each grab to the **first** enabled client for its protocol. There is no failover, so client order matters. The installer never configures the site-scraping `direct`/`browser` downloaders or ROM Hub plugins.

decypharr only symlinks extensions listed in its `allowed_file_types`, which ships as video/audio only. ROM torrents through it import nothing until ROM extensions (nsp, xci, iso, chd, rvz, gba, …) are added. `romarr.sh --wire` warns when they're missing.

### Known upstream issues (v1.0.0, RomM 5.3.1) and installer workarounds

- **RomM token expiry → library reads fail (worked around; [romarr#39](https://github.com/BlizzHacker/romarr/issues/39), [romm#4788](https://github.com/rommapp/romm/issues/4788)).** ROMarr re-authenticates only on a 401, but RomM 5.x answers an expired OAuth bearer with a **500** (an unhandled `OAuthCredentialsException`). Password auth therefore breaks about 30 minutes after every start: `readable: false`, and RomM logs 500s every 5 minutes. The installer creates a **non-expiring RomM client token** (`rmm_…`, scopes `me.read roms.read platforms.read collections.read tasks.run`) for the `romarr` account. It stores it as `token=` in `/opt/romm/.romarr_credentials` and sets it as the library's `api_key`: through `LIBRARY_API_KEY` on first run, or through the library API plus a restart via `--wire`.
- **Name-match import stall (worked around; [romarr#38](https://github.com/BlizzHacker/romarr/issues/38)).** Completed downloads are matched to the queue by `item.release == <client's torrent name>`. When the indexer title differs from the torrent's internal name (e.g. Nyaa "Pokemon Emerald Rom" vs RD "Pokemon Emerald (U).gba"), the item stays `grabbed` forever. `/etc/cron.d/romarr-recover` runs `romarr.sh --recover-stalled` every 5 minutes. It matches `grabbed` items older than 10 minutes (`ROMARR_STALL_MINUTES`) **by hash** (`release_id: btih:…`) against Real-Debrid's finished torrents and decypharr's qBit API, then Manual Imports the payload with the queued platform. It also removes the queue item and deletes the RD staging copy. Log: `/var/log/romarr-recover.log`.
- **RomM scan call rejected.** ROMarr calls `POST /api/tasks/run/scan_library` and gets `400 cannot be run` (RomM 5.x scans are socket.io-only). RomM's filesystem watcher (enabled by `romm.sh`) rescans 5 minutes after the import instead.
- **Matching can pick the wrong game or platform.** "Hollow Knight" picked *Silksong*; "Metroid Prime (ngc)" picked a Metroid Prime 4 Switch update. Review grabs rather than running fully unattended.
- **Password changes.** ROMarr has no change-password API; `ROMARR_PASSWORD` only applies while unclaimed. To change it: stop the container, back up `config/romarr.json`, delete `settings._password_hash`, set `ROMARR_PASSWORD` in `.env`, start. ROMarr is single-user (password only, no username).
- **Host networking.** ROMarr binds `0.0.0.0:<port>` with no bind option; keep the port firewalled.

---

## RomM

ROM manager and in-browser player ([rommapp/romm](https://github.com/rommapp/romm)). Scans a ROM library, enriches it from metadata providers, and plays games via EmulatorJS. Runs with a MariaDB sidecar.

**Install:** `ROMM_DOMAIN=romm.example.com bash romm.sh` (add `ROMM_IGDB_CLIENT_ID=... ROMM_IGDB_CLIENT_SECRET=...` etc., or answer the prompts)
**Update:** `bash romm.sh --update`
**Remove:** `bash romm.sh --remove` (purging config asks separately before deleting the ROM library)
**Providers:** `bash romm.sh --set-providers` (prompts, or `ROMM_*` env vars); `bash romm.sh --status` shows what is enabled
**Platforms:** `bash romm.sh --add-platforms psvita,xbox` (RomM `fs_slug`s)

### File Layout

| Path                                | Purpose                                                   |
| ----------------------------------- | --------------------------------------------------------- |
| `/opt/romm/docker-compose.yml`      | Compose file: `romm` + `romm-db` (recreated by installer) |
| `/opt/romm/.env`                    | All settings + secrets (600, root); preserved on update   |
| `/opt/romm/.admin_credentials`      | Generated admin login (600, root)                         |
| `/opt/romm/config/config.yml`       | Scan priorities, regions, media, exclusions (never overwritten) |
| `/opt/romm/library/roms/<platform>` | ROMs (Structure A: `roms/{platform}/{game}`)              |
| `/opt/romm/library/bios/<platform>` | Firmware/BIOS                                             |
| `/opt/romm/assets/`                 | Saves, states, screenshots                                |
| `/opt/romm/resources/`              | Scraped covers/screenshots/manuals                        |
| `/opt/romm/mysql/`                  | MariaDB datadir                                           |
| `/opt/romm/redis-data/`             | Embedded Valkey snapshot (cache, excluded from backup)    |
| `/etc/nginx/sites-available/romm`   | Subdomain vhost                                           |

### Features

- **Subdomain-only.** The SPA hardcodes `/` as its router base and calls `/api`, `/ws`, `/netplay` and `/assets` at the root. Upstream has no base-path setting (rommapp/romm#1551, #1604), so a subpath would mean `sub_filter` over ~1500 hashed JS chunks.
- **No setup wizard.** On first boot the installer uses RomM's setup API (open only while no admin exists) to create the platform folders and an admin account: the swizzin master user with its master password from `/root/.master.info`, the same login as the arrs (generated if the owner isn't the master user). Those calls need a CSRF cookie/header pair even unauthenticated; `_csrf_curl` handles it. The cookie is sent by hand because it is `Secure`.
- **Metadata providers.** The keyless ones are always on: Hasheous, LaunchBox, PlayMatch, Flashpoint, HowLongToBeat, TheGamesDB, Steam (plus libretro, which is built in). The keyed ones are IGDB, ScreenScraper, SteamGridDB, RetroAchievements and MobyGames. When RetroAchievements has a key, achievement progress sync is enabled.
- **Background tasks.** Rescan on filesystem change (5 min delay), nightly rescan at 03:00, Switch TitleDB and LaunchBox metadata refresh, WebP conversion, orphan cleanup. RomM has no REST trigger for a scan (it's socket.io-only), so new ROMs are picked up by the watcher.
- RomM runs as the app owner's uid:gid, so the library stays user-owned. MariaDB is pinned to the 11.8 LTS line so `--update` never jumps a major version.
- The vhost turns off request/response buffering so large ROM uploads and downloads stream, and upgrades WebSockets for socket.io. RomM's inner nginx keeps setting COEP/COOP for the EmulatorJS player.
- The cert check trusts `fullchain.pem`, not the `box install letsencrypt` exit code: that command can exit 0 after a failed http-01 challenge and leave an empty cert dir.

---

## Easynews-as-indexer

Bridge that wraps Easynews's proprietary file-level search behind a Newznab-compatible API, so the search index can be added to NZBHydra2 / Prowlarr / nzbdav as a Generic Newznab indexer. Image: [`ghcr.io/sanket9225/easynews_as_indexer`](https://github.com/Sanket9225/Easynews_as_indexer).

### File Layout

| Path                                       | Purpose                                 |
| ------------------------------------------ | --------------------------------------- |
| `/opt/easynews-indexer/docker-compose.yml` | Compose file (auto-generated)           |
| `/opt/easynews-indexer/.env` (chmod 600)   | `EASYNEWS_USER`, `EASYNEWS_PASS`, `NEWZNAB_APIKEY` |
| `/etc/systemd/system/easynews-indexer.service` | Systemd wrapper                     |
| `/install/.easynewsindexer.lock`           | Swizzin lock file                       |

Localhost-only — the bridge binds to `127.0.0.1:8081` and has no UI to expose. No nginx vhost, no panel entry.

### Features

- Single tiny Flask container (256M / 0.5 CPU caps)
- Easynews credentials prompted interactively, or read from `EASYNEWS_USER` / `EASYNEWS_PASS` env vars
- Newznab API key generated once on install (`openssl rand -hex 16`), persisted across re-runs
- Credentials pre-flighted against Easynews's search endpoint before container start (HTTP basic auth probe)
- **Auto-registers with NZBHydra2 if present** — appends "Easynews Bridge" to Hydra's indexers via `PUT /internalapi/config`, idempotent (skips if already there); `--remove` cleans it back out
- No SQLite DB, no application state — stateless bridge; backup keeps `.env` only

### Important caveats

- Easynews has no `tvdbid` / `imdbid` lookup, so Hydra forwards searches as `q=show name`. `STRICT_MATCHING=1` is enabled in the bridge env to compensate.
- Daily search/download limits live on the Easynews account, not the bridge — watch your Easynews dashboard if multiple arrs hammer it.
- Easynews backbone is Highwinds (same as Newshosting). The unique value is the **search index**, not the article store — don't add Easynews as a download provider if you already have Newshosting/UsenetServer.

---

## LitterBox

Cleanup tool for Real-Debrid libraries: counts and bulk-deletes broken / dead / virus-flagged / 451 "infringing_file" torrents that RD's May 2026 filter pushed into a "downloaded" state with no playable file.

### File Layout

| Path                                       | Purpose                          |
| ------------------------------------------ | -------------------------------- |
| `/opt/litterbox/docker-compose.yml`        | Compose file                     |
| `/etc/nginx/apps/litterbox.conf`           | Reverse proxy (subfolder)        |
| `/etc/systemd/system/litterbox.service`    | Systemd wrapper                  |
| `/install/.litterbox.lock`                 | Swizzin lock file                |

No data, config, or credentials live on disk — OAuth tokens stay in the user's browser localStorage. The proxy server is stateless by design.

### Features

- Single container from `ghcr.io/elfhosted/litterbox` (pinned tag)
- Stateless: no DB, no volumes, no on-disk secrets
- `read_only: true` + dropped capabilities + `no-new-privileges`
- Tight resource limits (256M RAM, 1 CPU) — proxy + static assets only
- nginx subfolder mount at `/litterbox/` with `sub_filter` rewriting `/static/` and `/api/` root-relative paths

### When to use

Run after Real-Debrid filter waves (May 2026 "infringing_file" 451s) to identify and bulk-delete torrents that RD has rendered unplayable. The detection uses RD's own `/unrestrict/link` API to surface ground-truth 451+error_code 35 responses, plus a fast filename regex for the bulk of known-blocked patterns.

If the public `litterbox.elfhosted.com` instance is being 451'd by RD (block at OAuth client_id or shared-IP level), running locally may still succeed because your IP and your OAuth session are different from theirs.

---

## Babysitarr

Self-healing monitoring daemon for the Radarr/Sonarr + Real-Debrid pipeline. Watches queue/import state, library files, and Decypharr's torrents.json, and applies corrective actions (clear stuck queue items, blocklist looping releases, re-search dead entries). Exposes a web dashboard at port 8284. Upstream: [DAdjadj/Babysitarr](https://github.com/DAdjadj/Babysitarr).

### File Layout

| Path                                       | Purpose                                                |
| ------------------------------------------ | ------------------------------------------------------ |
| `/opt/babysitarr/docker-compose.yml`       | Compose file (regenerated by installer)                |
| `/opt/babysitarr/.env` (chmod 600)         | `RD_API_KEY`, SMTP creds, Discord webhook              |
| `/opt/babysitarr/src/`                     | Cloned upstream repo (`docker compose build` source)   |
| `/opt/babysitarr/data/`                    | Persistent state (`babysitarr_state.json`) + logs       |
| `/etc/nginx/apps/babysitarr.conf`          | Reverse proxy (subfolder) with `auth_basic`            |
| `/etc/systemd/system/babysitarr.service`   | Systemd wrapper                                        |
| `/install/.babysitarr.lock`                | Swizzin lock file                                      |

### Features

- Builds from source (no published image): `git clone` → `docker compose build`
- Auto-discovers all installed Sonarr/Radarr instances (base + multi-instance) by walking `/install/*.lock` and parsing each arr's `config.xml` for port + API key
- `extra_hosts: host.docker.internal:host-gateway` so the container reaches Swizzin's native arrs at the host's loopback
- Mounts each arr's config dir read-only at `/arr-configs/<name>` for the indexer-reset feature (pokes the arr's SQLite DB directly)
- Mounts `~/.config/Decypharr` read-only when `torrents.json` exists (stuck-download detection)
- Babysitarr has no auth of its own — nginx enforces `auth_basic` against the Swizzin htpasswd
- Update path: `--update` re-runs `git pull` + `docker compose build` + recreate

### Important caveats

- **Swizzin runs Sonarr/Radarr/Decypharr as systemd services, not containers.** Babysitarr's "stalled imports → docker restart <arr>" and "stuck downloads → docker restart decypharr" auto-heal paths will silently no-op against native installs. Its pure-API checks (queue cleanup, blocklist, library missing-file scan, indexer-failure reset) still work.
- Overlaps with `watchdog/decypharr-watchdog.sh` and `watchdog/arr-stampede-watchdog.sh` — coordinate timeouts to avoid duplicate corrective actions.

---

## Common Docker Patterns

### Systemd Service Type

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose -f /opt/<app>/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/<app>/docker-compose.yml down
```

### Docker Installation

Docker Engine + Compose plugin are auto-installed if missing. The installer bypasses `apt_install` for Docker packages due to GPG key requirements.

### Container User

Containers run as the master user's UID:GID for file permission consistency with other Swizzin apps.
