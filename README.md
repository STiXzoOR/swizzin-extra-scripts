# Swizzin Scripts

A collection of installer scripts for integrating additional applications into [Swizzin](https://swizzin.ltd/), a self-hosted media server management platform.

## Available Scripts

| Script                                | Application                                                  | Description                                                      |
| ------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------- |
| [sonarr.sh](#sonarr)                  | [Sonarr](https://sonarr.tv/)                                 | Multi-instance Sonarr manager (4k, anime, etc.)                  |
| [radarr.sh](#radarr)                  | [Radarr](https://radarr.video/)                              | Multi-instance Radarr manager (4k, anime, etc.)                  |
| [cleanuparr.sh](#cleanuparr)          | [Cleanuparr](https://github.com/Cleanuparr/Cleanuparr)       | Download queue cleanup for \*arr apps                            |
| [decypharr.sh](#decypharr)            | [Decypharr](https://github.com/sirrobot01/decypharr)         | Encrypted file/torrent management via rclone and qBittorrent     |
| [notifiarr.sh](#notifiarr)            | [Notifiarr](https://github.com/Notifiarr/notifiarr)          | Notification relay client for \*arr apps and Plex                |
| [plex.sh](#plex)                      | [Plex](https://plex.tv/)                                     | Extended Plex installer with subdomain support                   |
| [emby.sh](#emby)                      | [Emby](https://emby.media/)                                  | Extended Emby installer with subdomain and Premiere bypass       |
| [jellyfin.sh](#jellyfin)              | [Jellyfin](https://jellyfin.org/)                            | Extended Jellyfin installer with subdomain support               |
| [organizr.sh](#organizr)              | [Organizr](https://github.com/causefx/Organizr)              | Extended Organizr installer with subdomain and SSO support       |
| [seerr.sh](#seerr)                    | [Seerr](https://github.com/seerr-team/seerr)                 | Media request platform (Overseerr fork)                          |
| [byparr.sh](#byparr)                  | [Byparr](https://github.com/ThePhaseless/Byparr)             | FlareSolverr alternative for bypassing anti-bot protections      |
| [flaresolverr.sh](#flaresolverr)      | [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) | Proxy server to bypass Cloudflare protection                     |
| [huntarr.sh](#huntarr)                | [Huntarr](https://github.com/plexguide/Huntarr.io)           | Automated media discovery for Sonarr, Radarr, Lidarr, etc.       |
| [subgen.sh](#subgen)                  | [Subgen](https://github.com/McCloudS/subgen)                 | Automatic subtitle generation using Whisper AI                   |
| [zurg.sh](#zurg)                      | [Zurg](https://github.com/debridmediamanager/zurg-testing)   | Real-Debrid WebDAV server with rclone mount                      |
| [lingarr.sh](#lingarr)                | [Lingarr](https://github.com/lingarr-translate/lingarr)      | Extended Lingarr installer with subdomain support (Docker-based) |
| [stremthru.sh](#stremthru)            | [StremThru](https://github.com/MunifTanjim/stremthru)        | Debrid streaming proxy with store management                     |
| [aiostreams.sh](#aiostreams)          | [AIOStreams](https://github.com/Viren070/AIOStreams)         | Stremio super-addon consolidating debrid services and addons     |
| [remux.sh](#remux)                    | [Remux](https://github.com/lostb1t/remux)                    | Jellyfin-compatible media server aggregating Stremio/WebDAV/local sources |
| [mediafusion.sh](#mediafusion)        | [MediaFusion](https://github.com/mhdzumair/MediaFusion)      | Stremio/Kodi add-on with Torznab API for Prowlarr               |
| [zilean.sh](#zilean)                  | [Zilean](https://github.com/iPromKnight/zilean)              | DMM hashlist Torznab indexer for debrid content                  |
| [nzbdav.sh](#nzbdav)                  | [NzbDav](https://github.com/infinidysk/infinidysk)                  | NZB-to-WebDAV bridge for debrid download clients                 |
| [newtarr.sh](#newtarr)               | [Newtarr](https://github.com/plexguide/Newtarr)             | Media library search tool (ElfHosted Huntarr fork)               |
| [litterbox.sh](#litterbox)           | [LitterBox](https://github.com/elfhosted/litterbox)         | Real-Debrid library cleaner (bulk-deletes 451/infringing torrents) |
| [nzbhydra2.sh](#nzbhydra2)            | [NZBHydra2](https://github.com/theotherp/nzbhydra2)         | Newznab/Torznab meta-search fronting multiple usenet indexers      |
| [easynews-indexer.sh](#easynews-indexer) | [Easynews-as-indexer](https://github.com/Sanket9225/Easynews_as_indexer) | Wraps Easynews's proprietary search as a Newznab indexer for the *arr stack |
| [babysitarr.sh](#babysitarr)          | [Babysitarr](https://github.com/DAdjadj/Babysitarr)         | Self-healing daemon for Radarr/Sonarr + Real-Debrid (Docker, builds from source) |
| [netdata.sh](#netdata)                | [Netdata](https://github.com/netdata/netdata)                | Real-time performance and health monitoring (1s granularity)     |
| [adguardhome.sh](#adguardhome)        | [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)   | Caching + ad-blocking DNS resolver (127.0.0.1:5353)              |
| [tailscale.sh](#tailscale)            | [Tailscale](https://tailscale.com/)                          | Mesh VPN install (apt repo + tailscaled, optional TS_AUTHKEY auth) |
| [mdblist-filter-proxy.sh](#mdblist-filter-proxy) | -                                                 | Local proxy that strips null tvdbid/tmdbid from mdblist.com lists so Sonarr CustomImport / Radarr lists don't crash |
| [dns-fix.sh](#dns-fix)                | -                                                            | Fix DNS issues for FlareSolverr/Byparr cookie validation         |
| [watchdog/](#service-watchdog)        | -                                                            | Service watchdog with health checks and auto-restart             |
| [backup/](#backup-system)             | -                                                            | BorgBackup-based backup system for any SSH borg server           |
| [swizzin-app-info](#swizzin-app-info) | -                                                            | Discover installed apps and extract URLs, API keys, config paths |

## Requirements

- A working [Swizzin](https://swizzin.ltd/) installation
- Root access to the server
- Internet connectivity for downloading dependencies

## Installation

```bash
# Switch to root
sudo su -

# Download the script
wget https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/<script>.sh
# or
curl -O https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/<script>.sh

# Make executable and run
chmod +x ~/<script>.sh
~/<script>.sh
```

## Scripts

### Sonarr

Multi-instance Sonarr manager. Installs the base Sonarr app if needed, then allows adding named instances (e.g., 4k, anime, kids).

```bash
# Install base + add instances interactively
bash sonarr.sh

# Add a specific instance
bash sonarr.sh --add 4k

# List all instances
bash sonarr.sh --list

# Remove instances (interactive)
bash sonarr.sh --remove

# Remove specific instance
bash sonarr.sh --remove 4k

# Remove without prompts
bash sonarr.sh --remove 4k --force
```

**Instance naming:** Alphanumeric only (e.g., `4k`, `anime`, `kids`, `remux`)

**Per-instance files:**

- Config: `/home/<user>/.config/sonarr-<name>/`
- Service: `sonarr-<name>.service`
- Access: `https://your-server/sonarr-<name>/`

**Note:** Base Sonarr is installed via `box install sonarr`. Instances share the binary at `/opt/Sonarr/` but have separate configs and ports.

---

### Radarr

Multi-instance Radarr manager. Installs the base Radarr app if needed, then allows adding named instances (e.g., 4k, anime, kids).

```bash
# Install base + add instances interactively
bash radarr.sh

# Add a specific instance
bash radarr.sh --add 4k

# List all instances
bash radarr.sh --list

# Remove instances (interactive)
bash radarr.sh --remove

# Remove specific instance
bash radarr.sh --remove 4k

# Remove without prompts
bash radarr.sh --remove 4k --force
```

**Instance naming:** Alphanumeric only (e.g., `4k`, `anime`, `kids`, `remux`)

**Per-instance files:**

- Config: `/home/<user>/.config/radarr-<name>/`
- Service: `radarr-<name>.service`
- Access: `https://your-server/radarr-<name>/`

**Note:** Base Radarr is installed via `box install radarr`. Instances share the binary at `/opt/Radarr/` but have separate configs and ports.

---

### Cleanuparr

Automates cleanup of stalled, incomplete, or blocked downloads from your \*arr applications. From the creators of Huntarr.

```bash
# Optional: Set custom owner (defaults to master user)
export CLEANUPARR_OWNER="username"

bash cleanuparr.sh

# Remove (will ask about purging config)
bash cleanuparr.sh --remove
```

**Access:** `https://your-server/cleanuparr/`

**Config:** `/opt/cleanuparr/config/cleanuparr.json`

**Features:**

- Removes stalled, incomplete, or malicious downloads
- Blocks problematic torrents across supported services
- Triggers automatic searches to replace deleted content
- Supports Sonarr, Radarr, Lidarr, Readarr, Whisparr
- Supports qBittorrent, Transmission, Deluge, uTorrent

---

### Decypharr

Manages encrypted files and torrents using rclone integration with qBittorrent.

```bash
# Optional: Set custom owner (defaults to master user)
export DECYPHARR_OWNER="username"

bash decypharr.sh
```

**Access:** `https://your-server/decypharr/`

**Config:** `/home/<user>/.config/Decypharr/config.json`

---

### Notifiarr

Official client for [Notifiarr.com](https://notifiarr.com/) - provides notifications and integrations for \*arr apps, Plex, and more.

```bash
# Optional: Set custom owner
export NOTIFIARR_OWNER="username"

# You will be prompted for your Notifiarr API key during installation
bash notifiarr.sh
```

**Access:** `https://your-server/notifiarr/`

**Config:** `/home/<user>/.config/Notifiarr/notifiarr.conf`

**Login:** Username: `admin` | Password: your API key (can be changed in Profile page)

---

### Plex

Extended Plex installer with subdomain support. Installs Plex via `box install plex` if not installed, optionally converts to subdomain mode.

```bash
# Interactive setup (installs Plex, asks about subdomain)
bash plex.sh

# Convert to subdomain mode (prompts for domain)
bash plex.sh --subdomain

# Revert to subfolder mode
bash plex.sh --subdomain --revert

# Complete removal
bash plex.sh --remove
```

**Subdomain Access:** `https://plex.example.com/`

**Subfolder Access:** `https://your-server/plex/`

**Features:**

- Interactive domain prompt (or set `PLEX_DOMAIN` env var to bypass)
- Automatic Let's Encrypt certificate
- Proper X-Plex-\* proxy headers for client communication
- Frame-ancestors CSP header for Organizr embedding (if configured)

---

### Emby

Extended Emby installer with subdomain support and Emby Premiere bypass. Installs Emby via `box install emby` if not installed.

```bash
# Interactive setup (installs Emby, asks about subdomain and Premiere)
bash emby.sh

# Convert to subdomain mode (prompts for domain)
bash emby.sh --subdomain

# Revert to subfolder mode
bash emby.sh --subdomain --revert

# Enable Emby Premiere bypass
bash emby.sh --premiere

# Disable Emby Premiere bypass
bash emby.sh --premiere --revert

# Complete removal
bash emby.sh --remove
```

**Subdomain Access:** `https://emby.example.com/`

**Subfolder Access:** `https://your-server/emby/`

**Features:**

- Interactive domain prompt (or set `EMBY_DOMAIN` env var to bypass)
- Automatic Let's Encrypt certificate
- Range/If-Range headers for proper media streaming
- Frame-ancestors CSP header for Organizr embedding (if configured)

**Premiere Bypass:**

- Intercepts Emby's license validation requests locally
- Creates self-signed certificate for `mb3admin.com`
- Adds certificate to system CA trust
- Patches `/etc/hosts` to redirect validation
- Computes and displays Premiere key for reference

---

### Jellyfin

Extended Jellyfin installer with subdomain support. Installs Jellyfin via `box install jellyfin` if not installed.

```bash
# Interactive setup (installs Jellyfin, asks about subdomain)
bash jellyfin.sh

# Convert to subdomain mode (prompts for domain)
bash jellyfin.sh --subdomain

# Revert to subfolder mode
bash jellyfin.sh --subdomain --revert

# Complete removal
bash jellyfin.sh --remove
```

**Subdomain Access:** `https://jellyfin.example.com/`

**Subfolder Access:** `https://your-server/jellyfin/`

**Features:**

- Interactive domain prompt (or set `JELLYFIN_DOMAIN` env var to bypass)
- Automatic Let's Encrypt certificate
- WebSocket support via `/socket` location
- WebOS LG TV CORS headers
- Range/If-Range headers for proper media streaming
- Prometheus `/metrics` endpoint with private network restrictions

---

### Organizr

Extended Organizr installer with subdomain and SSO support. Installs Organizr via `box install organizr` if not installed.

```bash
# Interactive setup (installs Organizr, asks about subdomain)
bash organizr.sh

# Convert to subdomain mode (prompts for domain)
bash organizr.sh --subdomain

# Revert to subfolder mode
bash organizr.sh --subdomain --revert

# Modify which apps are protected by SSO
bash organizr.sh --configure

# Fix auth_request placement in redirect blocks
bash organizr.sh --migrate

# Complete removal
bash organizr.sh --remove
```

**Subdomain Access:** `https://organizr.example.com/`

**Subfolder Access:** `https://your-server/organizr/`

**Config:** `/opt/swizzin-extras/organizr-auth.conf`

**Features:**

- Interactive domain prompt (or set `ORGANIZR_DOMAIN` env var to bypass)
- Automatic Let's Encrypt certificate
- SSO authentication for selected apps (replaces htpasswd)
- Interactive app selection menu
- Configurable auth levels per app (Admin, User, etc.)

**Auth Levels:** 0=Admin, 1=Co-Admin, 2=Super User, 3=Power User, 4=User, 998=Logged In

**Notes:**

- Swizzin's automated Organizr wizard may fail. If Organizr shows the setup wizard, complete it manually at your subdomain URL.

---

### Seerr

Media request and discovery platform (Overseerr fork) with Plex/Jellyfin integration.

```bash
# Interactive setup (prompts for domain)
bash seerr.sh

# Convert to subdomain mode
bash seerr.sh --subdomain

# Revert to direct port access
bash seerr.sh --subdomain --revert

# Complete removal
bash seerr.sh --remove

# Optional: Set custom owner
export SEERR_OWNER="username"
```

**Access:** `https://seerr.example.com/`

**Config:** `/home/<user>/.config/Seerr/`

---

### Byparr

FlareSolverr-compatible alternative using Camoufox browser for bypassing anti-bot protections. Used by Prowlarr and other \*arr apps.

```bash
# Optional: Set custom owner
export BYPARR_OWNER="username"

bash byparr.sh
```

**Port:** 8191 (FlareSolverr default for drop-in compatibility)

**Config:** `/home/<user>/.config/Byparr/env.conf`

**Prowlarr Setup:** Add as FlareSolverr indexer proxy with URL `http://127.0.0.1:8191`

**Note:** Byparr and FlareSolverr both use port 8191 - only one can be installed at a time.

**Troubleshooting:** If you get "cookies not valid" errors, run `bash dns-fix.sh` to fix DNS resolution issues.

---

### FlareSolverr

Proxy server to bypass Cloudflare and DDoS-GUARD protection. Used by Prowlarr, Jackett, and other \*arr apps to access protected indexers.

```bash
# Optional: Set custom owner
export FLARESOLVERR_OWNER="username"

bash flaresolverr.sh
```

**Port:** 8191 (default FlareSolverr port)

**Config:** `/home/<user>/.config/FlareSolverr/env.conf`

**Prowlarr/Jackett Setup:** Add as FlareSolverr indexer proxy with URL `http://127.0.0.1:8191`

**Note:** FlareSolverr only supports x64/amd64 architecture. For ARM systems, use [Byparr](#byparr) instead. Both use port 8191 - only one can be installed at a time.

**Troubleshooting:** If you get "cookies not valid" errors, run `bash dns-fix.sh` to fix DNS resolution issues.

---

### Huntarr

Automated media discovery tool that systematically searches for missing and upgradeable content across your \*arr applications.

```bash
# Optional: Set custom owner
export HUNTARR_OWNER="username"

bash huntarr.sh
```

**Access:** `https://your-server/huntarr/`

**Config:** `/home/<user>/.config/Huntarr/env.conf`

**Post-Install:** Configure your \*arr app connections via the web UI.

---

### Subgen

Automatic subtitle generation for your media library using OpenAI's Whisper AI model. Integrates with Plex, Jellyfin, and Emby via webhooks.

```bash
# Optional: Set custom owner
export SUBGEN_OWNER="username"

bash subgen.sh
```

**Webhook URL:** `http://127.0.0.1:<port>/webhook`

**Config:** `/home/<user>/.config/Subgen/env.conf`

**Default Settings:**

- Model: `medium` (balance of speed and accuracy)
- Device: auto-detected (`gpu` if NVIDIA GPU with drivers found, otherwise `cpu`)
- Format: `srt`

**Media Server Setup:**

- **Plex:** Settings → Webhooks → Add `http://127.0.0.1:<port>/webhook`
- **Jellyfin:** Plugins → Webhook → Add endpoint
- **Emby:** Server → Webhooks → Add URL

---

### Zurg

Self-hosted Real-Debrid WebDAV server that mounts your debrid library as a local filesystem using rclone.

```bash
# Optional: Set custom owner
export ZURG_OWNER="username"

# You will be prompted for your Real-Debrid API token during installation
bash zurg.sh
```

**Port:** 9999 (WebDAV server)

**Mount Point:** `/mnt/zurg` (your Real-Debrid library)

**Config:** `/home/<user>/.config/zurg/config.yml`

**Services:**

- `zurg.service` - The WebDAV server
- `rclone-zurg.service` - The filesystem mount

**Get your API token:** https://real-debrid.com/apitoken

**Usage with \*arr apps:** Point your \*arr applications to `/mnt/zurg` for accessing Real-Debrid content.

---

### Lingarr

Extended Lingarr installer with subdomain support. Automatic subtitle translation using multiple translation services (LibreTranslate, DeepL, OpenAI, Anthropic, Google, and more). Docker-based application managed via Docker Compose.

```bash
# Optional: Set custom owner
export LINGARR_OWNER="username"

# Interactive setup (installs Lingarr, asks about subdomain)
bash lingarr.sh

# Convert to subdomain mode (prompts for domain)
bash lingarr.sh --subdomain

# Revert to subfolder mode
bash lingarr.sh --subdomain --revert

# Update to latest version
bash lingarr.sh --update

# Remove (will ask about purging config)
bash lingarr.sh --remove

# Remove without prompts
bash lingarr.sh --remove --force
```

**Subdomain Access:** `https://lingarr.example.com/`

**Subfolder Access:** `https://your-server/lingarr/`

**Config:** `/opt/lingarr/config/`

**Features:**

- Auto-installs Docker Engine + Compose if not present
- Auto-discovers media paths from Sonarr/Radarr (base + multi-instance)
- Auto-discovers Sonarr/Radarr API credentials for integration
- SQLite database (zero configuration)
- Subdomain mode with clean URLs (recommended) or subfolder mode with sub_filter rewriting
- Interactive domain prompt (or set `LINGARR_DOMAIN` env var to bypass)
- Automatic Let's Encrypt certificate (subdomain mode)
- Frame-ancestors CSP header for Organizr embedding (if configured)
- `--update` flag pulls latest Docker image and recreates container
- Supports 10+ translation backends configurable via web UI

**Docker files:**

- Compose: `/opt/lingarr/docker-compose.yml`
- Service: `lingarr.service` (systemd wrapper for Docker Compose)

**Post-Install:** Configure your preferred translation service via the Lingarr web UI.

---

### NZBHydra2

Newznab/Torznab meta-search that fronts multiple usenet indexers (NZBgeek, NzbPlanet, NZBFinder, DrunkenSlug, etc.) behind a single endpoint. Used so Prowlarr → arrs only know about one usenet indexer (Hydra), while Hydra handles fan-out, dedup, and aggregation across N upstream indexers.

```bash
bash nzbhydra2.sh                 # Install
bash nzbhydra2.sh --update        # Pull latest image and recreate
bash nzbhydra2.sh --remove        # Remove (asks about purging config)
bash nzbhydra2.sh --remove --force
bash nzbhydra2.sh --register-panel
```

**Access:** `https://your-server/nzbhydra2/`

**Config:** `/opt/nzbhydra2/config/nzbhydra.yml` (+ SQLite at `config/database/`)

**Features:**

- Auto-installs Docker Engine + Compose if not present
- LSIO image (`lscr.io/linuxserver/nzbhydra2`) with PUID/PGID/TZ honored
- Pre-configures `urlBase: /nzbhydra2` so the UI works under subpath out of the box (start → wait for config → patch urlBase → restart, automated in installer)
- nginx reverse proxy with subpath, htpasswd auth on UI, no-auth `/api` for downstream clients
- Panel + Organizr integration
- 1 GB memory cap (Spring Boot Java app)

**Post-Install:**

1. Open `https://your-server/nzbhydra2/` and complete Settings > Authentication (recommended)
2. Settings > Indexers > Add Newznab — fill in URL + API key for each upstream
3. Copy Hydra's main API key (Settings > Main > API key) and add as a Newznab indexer in Prowlarr, pointing at `http://127.0.0.1:<port>/nzbhydra2/`
4. Disable the direct upstream indexers in Prowlarr (Hydra now fronts them)

---

## Utility Scripts

### MDBList Filter Proxy

Local HTTP proxy that strips `tvdbid: null` / `tmdbid: null` from mdblist.com list payloads before they reach Sonarr/Radarr. Sonarr's `CustomImport` deserializes those numeric IDs as `System.Int32` and fails the **entire list** the moment it sees a null, surfacing as:

```
Error converting value {null} to type 'System.Int32'
```

The proxy fetches upstream, removes null int fields per item (Sonarr then ignores them rather than crashing), and drops items with no usable id (no tvdbid/tmdbid/imdb_id at all).

```bash
# Install + enable + start (listens on 127.0.0.1:11550 by default)
bash mdblist-filter-proxy.sh

# Repoint every existing [mdblist-auto] list in Sonarr & Radarr at the proxy
bash mdblist-filter-proxy.sh --rewrite-arr

# Status / logs
bash mdblist-filter-proxy.sh --status

# Roll lists back to mdblist.com (do this BEFORE removing the proxy)
bash mdblist-filter-proxy.sh --rewrite-arr-undo

# Remove
bash mdblist-filter-proxy.sh --remove
```

**What gets installed:**

- `/usr/local/bin/mdblist-filter-proxy.py` — Python stdlib HTTP server
- `/etc/systemd/system/mdblist-filter-proxy.service` — runs as the *arr user
- Systemd hardening (ProtectSystem=strict, PrivateTmp, NoNewPrivileges, etc.)

**Override defaults via env (set before install):**

- `MDBLIST_PROXY_HOST` — bind host (default `127.0.0.1`)
- `MDBLIST_PROXY_PORT` — bind port (default `11550`)
- `MDBLIST_PROXY_TTL` — response cache seconds (default `300`)

**To use a list manually:** replace `https://mdblist.com` with `http://127.0.0.1:11550` in the list URL field of any Sonarr `CustomImport` or Radarr `RadarrListImport` import list.

---

### DNS Fix

Fixes DNS resolution issues that can cause "cookies not valid" errors when using FlareSolverr or Byparr with Jackett indexers.

```bash
# Check current DNS status
bash dns-fix.sh --status

# Apply full fix (configure public DNS, optionally disable IPv6)
bash dns-fix.sh

# Only disable IPv6 (no DNS changes)
bash dns-fix.sh --disable-ipv6

# Re-enable IPv6
bash dns-fix.sh --enable-ipv6

# Revert all changes to original configuration
bash dns-fix.sh --revert
```

**What it does:**

- Configures system to use public DNS (8.8.8.8, 1.1.1.1)
- Optionally disables IPv6 (can cause resolution mismatches)
- Backs up original configuration
- Automatically restarts affected services (byparr, flaresolverr, jackett)

**When to use:** If Jackett reports "The cookies provided by FlareSolverr are not valid" when testing indexers.

---

### Service Watchdog

Monitors services via process state and HTTP health checks, automatically restarts unhealthy services with cooldown protection, and sends notifications.

```bash
# Interactive setup (installs watchdog for Emby)
bash watchdog/emby-watchdog.sh

# Install watchdog
bash watchdog/emby-watchdog.sh --install

# Show current status
bash watchdog/emby-watchdog.sh --status

# Clear backoff state, resume monitoring
bash watchdog/emby-watchdog.sh --reset

# Remove watchdog
bash watchdog/emby-watchdog.sh --remove
```

**How it works:**

1. Cron runs every 2 minutes
2. Checks process state (`systemctl is-active`)
3. Checks HTTP health endpoint (configurable URL + expected response)
4. If unhealthy, restarts the service
5. Rate-limited: max 3 restarts per 15 minutes
6. Enters backoff mode if max restarts exceeded
7. Sends notifications (Discord, Pushover, Notifiarr, email)

**Notifications:** During installation, you'll be prompted to configure notification channels. All are optional - leave empty to skip.

**Repository files:**

```
watchdog/
├── watchdog.sh               # Generic watchdog engine
├── emby-watchdog.sh          # Emby-specific installer/manager
└── configs/
    ├── watchdog.conf.example       # Global config template
    └── emby-watchdog.conf.example  # Emby config template
```

**Runtime files (on server):**
| File | Purpose |
|------|---------|
| `/opt/swizzin-extras/watchdog.sh` | Generic watchdog engine |
| `/opt/swizzin-extras/watchdog.conf` | Global config (notifications) |
| `/opt/swizzin-extras/watchdog.d/emby.conf` | Emby-specific config |
| `/var/log/watchdog/emby.log` | Log file |
| `/etc/cron.d/emby-watchdog` | Cron job |

**Status output example:**

```
Emby Watchdog Status
━━━━━━━━━━━━━━━━━━━━
Service:     emby-server (active)
Health:      http://127.0.0.1:8096/emby/System/Info/Public (OK)
Restarts:    0/3 in current window
State:       monitoring
```

**Adding other services:** The watchdog engine is generic. Copy `watchdog/emby-watchdog.sh`, adjust `SERVICE_NAME`, `HEALTH_URL`, and `HEALTH_EXPECT` for your target service (Plex, Jellyfin, etc.).

---

### Backup System

BorgBackup-based backup system supporting any SSH-accessible borg server (Hetzner Storage Box, Rsync.net, BorgBase, self-hosted).

```bash
# Copy backup folder to server and run interactive setup wizard
cd backup/
bash swizzin-backup-install.sh

# Or manually install files and configure
cp swizzin-backup.sh /usr/local/bin/ && chmod +x /usr/local/bin/swizzin-backup.sh
cp swizzin-restore.sh /usr/local/bin/ && chmod +x /usr/local/bin/swizzin-restore.sh
# ... (see backup/README.md for full manual setup)

# Run backup manually
swizzin-backup.sh

# Dry run - show what would be backed up
swizzin-backup.sh --dry-run

# List archives
swizzin-backup.sh --list

# Show discovered services
swizzin-backup.sh --services

# Restore (interactive wizard)
swizzin-restore.sh

# Restore single app
swizzin-restore.sh --app sonarr

# Mount archive for browsing
swizzin-restore.sh --mount
```

**Supported backup targets:**

- Hetzner Storage Box
- Rsync.net
- BorgBase
- Self-hosted (any Linux server with borg installed)

**Features:**

- Automatic service stop/start for consistent SQLite backups
- Multi-instance app support (sonarr-4k, radarr-anime, etc.)
- Zurg `.zurgtorrent` file backup for Real-Debrid setups
- `/mnt/symlinks` backup for \*arr root folder symlinks
- Notifications via Discord, Pushover, Notifiarr, email
- Healthchecks.io integration
- GFS retention: 7 daily, 4 weekly, 6 monthly, 2 yearly
- Encrypted, deduplicated backups via BorgBackup

**What gets backed up:**

- Swizzin core, nginx, Let's Encrypt, systemd, cron
- All \*arr apps (configs, databases, multi-instance)
- Media servers (Plex, Emby, Jellyfin - config + DB only)
- Custom apps (Notifiarr, Decypharr, Zurg, Huntarr, etc.)
- Zurg `.zurgtorrent` files and \*arr root folder symlinks

**What's excluded:**

- Zurg data directory (except `.zurgtorrent` files)
- Media server caches and transcodes
- Remote mounts (`/mnt/zurg/`, `/mnt/remote/`)
- Application binaries (regenerable)

**Restore modes:**

- Full restore - rebuild entire server
- App restore - single app with service management
- FUSE mount - browse and extract specific files
- Extract path - extract specific directory to staging

See [backup/README.md](backup/README.md) for full documentation including setup wizard, service management, and troubleshooting.

---

### Swizzin App Info

A utility that discovers all installed Swizzin apps and extracts configuration details including URLs, API keys, and config file paths. Useful for automation, documentation, and debugging. Installable as a global command.

```bash
# Install globally (run once)
wget https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/swizzin-app-info
chmod +x swizzin-app-info
sudo ./swizzin-app-info --install

# Now use from anywhere:
swizzin-app-info                    # List all installed apps
swizzin-app-info --json             # Output as JSON (for scripting)
swizzin-app-info --app sonarr       # Show info for a specific app
swizzin-app-info --verbose          # Include config file paths

# Uninstall
sudo swizzin-app-info --uninstall
```

**Example output:**

```
App           URL                              API Key
--------------------------------------------------------------------------------
radarr        http://localhost:7878/radarr     a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
sonarr        http://localhost:8989/sonarr     z9y8x7w6v5u4t3s2r1q0p9o8n7m6l5k4
sonarr-4k     http://localhost:10001/sonarr-4k abc123def456ghi789jkl012mno345pq
plex          http://localhost:32400           xYz-AbC-123-PlexToken
bazarr        http://localhost:6767/bazarr     -
notifiarr     http://localhost:5454            notifiarr-api-key-here
```

**How it works:**

- Discovers installed apps via lock files in `/install/`
- Parses app config files (XML, JSON, YAML, INI, TOML, etc.)
- Falls back to nginx config or systemd environment if config not found
- Supports multi-instance apps (sonarr-4k, radarr-anime, bazarr-4k, etc.)

**JSON output fields:**

```json
{
  "app": "sonarr",
  "installed": true,
  "config_file": "/home/user/.config/Sonarr/config.xml",
  "port": "8989",
  "baseurl": "/sonarr",
  "apikey": "your-api-key-here",
  "full_url": "http://localhost:8989/sonarr"
}
```

**Supported apps:** All \*arr apps (Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr), media servers (Plex, Emby, Jellyfin), download clients (qBittorrent, Deluge, Transmission, NZBGet, SABnzbd), and custom apps from this repo (Cleanuparr, Decypharr, Huntarr, Notifiarr, Zurg, Lingarr, etc.).

**Requirements:** Python 3.6+ (no external dependencies)

---

## Environment Variables

All scripts now use **interactive prompts** for required values. Environment variables can be used to bypass prompts for automation.

| Variable                  | Script       | Description                                          |
| ------------------------- | ------------ | ---------------------------------------------------- |
| `PLEX_DOMAIN`             | plex.sh      | Public FQDN for Plex (bypasses prompt)               |
| `PLEX_LE_HOSTNAME`        | plex.sh      | Let's Encrypt hostname (defaults to domain)          |
| `PLEX_LE_INTERACTIVE`     | plex.sh      | Set to `yes` for interactive LE (CloudFlare DNS)     |
| `EMBY_DOMAIN`             | emby.sh      | Public FQDN for Emby (bypasses prompt)               |
| `EMBY_LE_HOSTNAME`        | emby.sh      | Let's Encrypt hostname                               |
| `EMBY_LE_INTERACTIVE`     | emby.sh      | Set to `yes` for interactive LE                      |
| `JELLYFIN_DOMAIN`         | jellyfin.sh  | Public FQDN for Jellyfin (bypasses prompt)           |
| `JELLYFIN_LE_HOSTNAME`    | jellyfin.sh  | Let's Encrypt hostname                               |
| `JELLYFIN_LE_INTERACTIVE` | jellyfin.sh  | Set to `yes` for interactive LE                      |
| `ORGANIZR_DOMAIN`         | organizr.sh  | Public FQDN for Organizr (bypasses prompt)           |
| `ORGANIZR_LE_HOSTNAME`    | organizr.sh  | Let's Encrypt hostname                               |
| `ORGANIZR_LE_INTERACTIVE` | organizr.sh  | Set to `yes` for interactive LE                      |
| `SEERR_DOMAIN`            | seerr.sh     | Public FQDN for Seerr (bypasses prompt)              |
| `SEERR_LE_HOSTNAME`       | seerr.sh     | Let's Encrypt hostname                               |
| `SEERR_LE_INTERACTIVE`    | seerr.sh     | Set to `yes` for interactive LE                      |
| `LINGARR_DOMAIN`          | lingarr.sh   | Public FQDN for Lingarr (bypasses prompt)            |
| `LINGARR_LE_HOSTNAME`     | lingarr.sh   | Let's Encrypt hostname                               |
| `LINGARR_LE_INTERACTIVE`  | lingarr.sh   | Set to `yes` for interactive LE                      |
| `DN_API_KEY`              | notifiarr.sh | Notifiarr.com API key (prompted if not set)          |
| `RD_TOKEN`                | zurg.sh      | Real-Debrid API token (prompted if not set)          |
| `<APP>_OWNER`             | All          | Application owner username (defaults to master user) |

## Panel Integration

All scripts automatically register with the Swizzin panel if installed. Apps appear in the panel with their icons and links.

## Uninstallation

All scripts support the `--remove` flag for complete uninstallation:

```bash
# Switch to root
sudo su -

# Download the script (if not already present)
wget https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/<script>.sh

# Run with --remove flag
bash <script>.sh --remove
```

This will:

- Stop and disable all related services
- Remove the application binary/directory
- Remove nginx configuration
- Remove from Swizzin panel
- Remove configuration files
- Clean up lock files

**Note:** Let's Encrypt certificates are not removed automatically.

## Architecture

Scripts follow a consistent pattern:

1. Source Swizzin utilities
2. Set application variables (port, paths, etc.)
3. Install dependencies and application
4. Create systemd service
5. Configure nginx reverse proxy (where applicable)
6. Register with Swizzin panel
7. Create lock file at `/install/.<app>.lock`

### Extended Installer Pattern

Media server scripts (plex.sh, emby.sh, jellyfin.sh, organizr.sh, seerr.sh, lingarr.sh) follow a unified pattern:

```bash
# Interactive setup - installs app, asks about features
bash <app>.sh

# Convert to subdomain mode
bash <app>.sh --subdomain

# Revert to subfolder mode
bash <app>.sh --subdomain --revert

# Complete removal
bash <app>.sh --remove
```

### Python Apps (uv-based)

Byparr, Huntarr, and Subgen use [uv](https://github.com/astral-sh/uv) for Python version and dependency management:

- uv is installed per-user at `~/.local/bin/uv`
- Applications are cloned to `/opt/<appname>`
- Systemd runs apps via `uv run python main.py`

## Contributing

1. Fork the repository
2. Create a feature branch
3. **Use a template** from `templates/` as your starting point:
   - `template-binary.sh` - For single-binary applications
   - `template-python.sh` - For Python apps using uv
   - `template-docker.sh` - For Docker Compose applications
   - `template-subdomain.sh` - For extended installers with subdomain support
   - `template-multiinstance.sh` - For multi-instance managers
4. Follow the coding standards in `CLAUDE.md`
5. Test on a Swizzin installation
6. Submit a pull request

See `CLAUDE.md` for detailed coding conventions and architecture documentation.

## License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Swizzin](https://swizzin.ltd/) - The media server management platform
- All the amazing open-source projects these scripts install
