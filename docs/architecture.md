# Architecture

## Script Structure

Each installer script follows this sequence:

1. `set -euo pipefail` for strict error handling
2. Source Swizzin utilities from `/etc/swizzin/sources/functions/utils`
3. Source shared libraries (`lib/utils.sh`, `lib/nginx-utils.sh`)
4. Load the panel helper (local repo copy, cache fallback)
5. Define app variables (port, paths, config directory)
6. Register cleanup trap handler (`trap cleanup EXIT`)
7. Execute installation functions:
   - `_install_<app>()` - Download, extract, configure
   - `_systemd_<app>()` - Create and enable systemd service
   - `_nginx_<app>()` - Configure reverse proxy (if nginx installed)
8. Register with Swizzin panel via `panel_register_app()`
9. Create lock file at `/install/.<appname>.lock`

## Binary Placement

| Type                 | Location                                    | Examples                                   |
| -------------------- | ------------------------------------------- | ------------------------------------------ |
| Single-file binaries | `/usr/bin/<appname>`                        | decypharr, notifiarr, zurg                 |
| Multi-file apps      | `/opt/<appname>/`                           | cleanuparr, seerr, byparr, huntarr, subgen, newtarr |
| Docker apps          | `/opt/<appname>/` with `docker-compose.yml` | lingarr, libretranslate, stremthru, aiostreams, mediafusion, zilean, nzbdav, litterbox, easynews-indexer, babysitarr |

## Files Overview

| Script              | Description                                                 |
| ------------------- | ----------------------------------------------------------- |
| `cleanuparr.sh`     | Download queue cleanup for \*arr apps                       |
| `decypharr.sh`      | Encrypted file/torrent management via rclone                |
| `notifiarr.sh`      | Notification relay for Starr apps                           |
| `seerr.sh`          | Media request platform with subdomain support               |
| `byparr.sh`         | FlareSolverr alternative (uv + Python 3.13)                 |
| `huntarr.sh`        | Automated media discovery for \*arr apps (uv)               |
| `subgen.sh`         | Whisper-based subtitle generation (uv + Python 3.11)        |
| `zurg.sh`           | Real-Debrid WebDAV server + rclone mount                    |
| `lingarr.sh`        | Subtitle translation (Docker, auto-discovers Sonarr/Radarr) |
| `libretranslate.sh` | Machine translation API (Docker, GPU auto-detection)        |
| `organizr.sh`       | SSO gateway with subdomain support                          |
| `plex.sh`           | Plex with subdomain support                                 |
| `emby.sh`           | Emby with subdomain + Premiere bypass                       |
| `jellyfin.sh`       | Jellyfin with subdomain support                             |
| `panel.sh`          | Swizzin panel subdomain support                             |
| `sonarr.sh`         | Multi-instance Sonarr manager                               |
| `radarr.sh`         | Multi-instance Radarr manager                               |
| `stremthru.sh`      | Debrid streaming proxy with store management (Docker)        |
| `aiostreams.sh`     | Stremio super-addon consolidating debrid services + addons (Docker, single container) |
| `mediafusion.sh`    | Stremio/Kodi add-on with Torznab API (Docker, 5 containers) |
| `zilean.sh`         | DMM hashlist Torznab indexer for debrid content (Docker)     |
| `nzbdav.sh`         | NZB-to-WebDAV bridge for debrid download clients (Docker)    |
| `newtarr.sh`        | Media library search tool (uv + Python)                      |
| `litterbox.sh`      | Real-Debrid library cleaner (Docker, stateless, on-demand)   |
| `nzbhydra2.sh`      | Newznab meta-search fronting multiple usenet indexers (Docker, Spring Boot) |
| `easynews-indexer.sh` | Easynews search → Newznab bridge (Docker, Flask; auto-registers with NZBHydra2) |
| `babysitarr.sh`     | Self-healing daemon for arrs + RD (Docker, builds from source; auto-discovers Sonarr/Radarr) |
| `netdata.sh`        | Real-time monitoring via upstream kickstart (bound to 127.0.0.1) |
| `adguardhome.sh`    | Caching ad-blocking DNS (127.0.0.1:5353, does not touch resolv.conf) |
| `tailscale.sh`      | Mesh VPN via the official Tailscale apt repo (TS_AUTHKEY env or interactive login URL) |
| `panel_helpers.sh`  | Shared panel registration utility                           |

## Shared Libraries

| Library              | Location            | Purpose                                          |
| -------------------- | ------------------- | ------------------------------------------------ |
| `lib/nginx-utils.sh` | Sourced by scripts  | `_reload_nginx()` - validated nginx reload       |
| `lib/utils.sh`       | Sourced by scripts  | `_sed_escape_value()` - safe sed replacement     |
| `lib/notifications.sh` | Sourced by watchdog/backup | Shared notification channels + rate limiting |

### lib/nginx-utils.sh

Provides `_reload_nginx()` which runs `nginx -t` before reloading. All scripts use this instead of bare `systemctl reload nginx`.

### lib/utils.sh

Provides `_sed_escape_value()` to escape `&`, `|`, `\` characters in sed replacement strings, preventing injection when substituting user-controlled values.

### lib/notifications.sh

Shared notification library used by the watchdog and backup systems. Supports Discord, Pushover, Notifiarr, and email. Includes `_should_notify()` rate limiter (default: 1 notification per 5 minutes per service).

Scripts override `_notify_log_warn()` before sourcing to use their own log format:

```bash
_notify_log_warn() { log_warn "$1"; }
. "${SCRIPT_DIR}/../lib/notifications.sh"
NOTIFY_RATE_DIR="$STATE_DIR"
```

## Function Naming

- `app_*` - Application configuration variables
- `_function_name()` - Private/internal functions (underscore prefix)
- Pattern: `_<action>_<appname>()` (e.g., `_install_seerr`, `_systemd_notifiarr`)

## Key Swizzin Functions

```bash
port <start> <end>           # Allocate free port in range
apt_install <packages>       # Install packages via apt
swizdb get/set               # Swizzin database operations
_get_master_username         # Get primary Swizzin user
_os_arch                     # Detect CPU architecture (amd64, arm64, armv6)
echo_progress_start/done     # Progress logging
echo_error, echo_info        # Status logging
ask "question?" Y/N          # Interactive yes/no prompts
```

## Port Allocation

Most installers use `port 10000 12000` to find an available port.

**Fixed ports:**

- Byparr: 8191 (FlareSolverr compatibility)
- Zurg: 9999 (WebDAV server default)

## Integration Points

| Component          | Location                               |
| ------------------ | -------------------------------------- |
| Swizzin utilities  | `/etc/swizzin/sources/functions/utils` |
| Swizzin database   | `swizdb` command                       |
| Panel registration | `/opt/swizzin/core/custom/profiles.py` |
| Lock files         | `/install/.<appname>.lock`             |
| Logs               | `/root/logs/swizzin.log`               |
| Shared libraries   | `lib/nginx-utils.sh`, `lib/utils.sh`, `lib/notifications.sh` |
| Watchdog state     | `/var/lib/watchdog/`                   |
| Notification rate  | `/var/lib/watchdog/<service>.notify_ts` |

## Python Apps (uv-based)

Byparr, Huntarr, Subgen, and Newtarr use `uv` for Python management:

- uv installed per-user at `~/.local/bin/uv`
- Apps cloned to `/opt/<appname>`
- Dependencies via `uv sync` or `uv add`
- Systemd runs apps via `uv run python <entry>.py`
- Subgen runs `subgen.py` directly (not `launcher.py`), auto-detects NVIDIA GPU

## Nginx Configuration

| App Type                               | Pattern                                                    |
| -------------------------------------- | ---------------------------------------------------------- |
| Cleanuparr/Decypharr/Notifiarr/Huntarr | Location-based at `/<appname>/`                            |
| Lingarr                                | Subfolder (`/lingarr/` with sub_filter) or subdomain vhost |
| Seerr                                  | Dedicated vhost with frame-ancestors CSP                   |
| Organizr                               | Dedicated vhost at `/etc/nginx/sites-available/organizr`   |
| Plex/Emby/Jellyfin                     | Dedicated vhosts with panel meta urloverride               |
| StremThru/MediaFusion/NzbDAV           | Subfolder with sub_filter + auth bypass for API endpoints  |
| Zilean                                 | Subfolder at `/<appname>/`                                 |
| Newtarr                                | Subfolder at `/<appname>/`                                 |
| Byparr/Subgen/Zurg                     | No nginx (internal API/webhook services)                   |

API endpoints bypass htpasswd authentication.

## Panel Icons

For apps with their own logo:

```bash
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/myapp.png"
```

For apps without a logo (uses placeholder):

```bash
app_icon_name="placeholder"
app_icon_url=""
```
