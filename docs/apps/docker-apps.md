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

Stremio/Kodi universal add-on with native Torznab API for Prowlarr. 5-container stack.

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

- 5 containers: app, worker (Dramatiq), PostgreSQL, Redis, Browserless (headless Chrome)
- Main container uses entrypoint sed to patch gunicorn bind port dynamically
- `HOST_URL` env var set from Organizr domain detection chain
- Comprehensive `sub_filter` rules for SPA JavaScript path rewriting
- Custom Prowlarr Cardigann indexer definition deployed from `resources/prowlarr/mediafusion.yml`
- Torznab and manifest endpoints bypass auth for Prowlarr/Stremio access

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

### File Layout

| Path                                | Purpose                                     |
| ----------------------------------- | ------------------------------------------- |
| `/opt/remux/docker-compose.yml`     | Compose file (recreated by installer)       |
| `/opt/remux/data/`                  | All state: SQLite DB, config, logs, caches  |
| `/etc/nginx/sites-available/remux`  | Subdomain vhost                             |
| `/etc/systemd/system/remux.service` | Systemd wrapper                             |
| `/install/.remux.lock`              | Swizzin lock file                           |

### Features

- **Subdomain-only** — Jellyfin-compatible clients need a clean root URL and Remux has no base-path support. Vhost mirrors emby.sh: WebSocket map, streaming timeouts (1h), `proxy_buffering off`, Range passthrough. No nginx basic auth — Remux has its own user management.
- Runs as the app owner's uid:gid with `HOME=/data` (the bundled rqbit torrent engine aborts without a writable `$HOME/.cache`; everything else is baked to write under `/data`).
- `/mnt` mounted read-only with `rslave` so `/mnt/symlinks` and the FUSE-backed rclone mounts it points into (zurg, nzbdav) resolve in-container and survive host remounts.
- Release channels: `:latest` (stable, default) / `:nightly` via `--latest`, persisted in swizdb like aiostreams.
- Healthcheck against the container's `/health` endpoint (returns 200 unauthenticated).
- Admin dashboard at `/dashboard`; sources (WebDAV/Stremio/local) are configured there, not via env vars.

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
