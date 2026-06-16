# Decypharr

qBittorrent-compatible mock server with Debrid + Usenet support. Sits in front of Sonarr/Radarr as a download client and pulls content through Real-Debrid / AllDebrid / DebridLink / TorBox (via qBittorrent API) or through Usenet providers (via Sabnzbd API).

Installer uses the [STiXzoOR/decypharr](https://github.com/STiXzoOR/decypharr) fork — tracks upstream sirrobot01/decypharr with two Swizzin-specific patches (URLBase reverse-proxy fix, DebridLink nil-map panic fix). The pinned tag is set via `DECYPHARR_FORK_TAG` at the top of `decypharr.sh`.

## Service

Single systemd unit:

| Service             | Purpose                     |
| ------------------- | --------------------------- |
| `decypharr.service` | Binary + FUSE mount (if on) |

`KillMode=control-group` prevents orphaned rclone processes on restart.

## Port

Dynamic via `port 10000 12000` — recorded in swizdb as nginx reverse-proxies to it. Query:

```bash
swizzin-app-info --app decypharr
```

## Key Files

| Path                                         | Purpose                                             |
| -------------------------------------------- | --------------------------------------------------- |
| `/usr/bin/decypharr`                         | Binary                                              |
| `/home/$USER/.config/Decypharr/config.json`  | App config (URL base, debrid + mount schema)        |
| `/home/$USER/.config/Decypharr/auth.json`    | Credentials + API token (generated on first-run)    |
| `/home/$USER/.config/Decypharr/torrents.json`| Torrent state                                       |
| `/home/$USER/.config/Decypharr/logs/`        | Application logs (watched by watchdog)              |
| `/etc/systemd/system/decypharr.service`      | Service unit                                        |
| `/etc/nginx/apps/decypharr.conf`             | Reverse proxy (carries `decypharr-nginx-schema: N`) |
| `/install/.decypharr.lock`                   | Install marker                                      |

## Nginx

Three proxy blocks, all under `/decypharr/`:

| Block                           | Auth           | Why                                                     |
| ------------------------------- | -------------- | ------------------------------------------------------- |
| `location ^~ /decypharr/`       | `auth_basic`   | Web UI — forces Swizzin's htpasswd on the user          |
| `location ^~ /decypharr/api/`   | `auth_request off` | qBit-compatible API (Sonarr/Radarr download client)  |
| `location ^~ /decypharr/sabnzbd/api` | `auth_request off` | Sabnzbd-compatible API (Usenet flow — v2 only)   |

The config file starts with a schema marker comment:

```
# decypharr-nginx-schema: 2
```

The installer's `--update` reads this on every run and automatically regenerates the nginx block when the installer's `DECYPHARR_NGINX_SCHEMA` advances past what's on disk. Do not delete or modify that line — it'll trigger an unwanted refresh or silently keep stale rules in place.

## Mount Mode

Two mount modes, picked automatically at install:

| Mode        | Trigger                      | What Decypharr does                            |
| ----------- | ---------------------------- | ---------------------------------------------- |
| `rclone`    | Zurg not installed           | Embedded rclone mounts each debrid at `/mnt/<provider>/` |
| `none`      | `/install/.zurg.lock` exists | Skips its own mount; reads zurg's `/mnt/zurg/` directly via `debrid.folder` |

The mode ends up in `config.json` at `mount.type`. Two other modes (`dfs`, `external_rclone`) exist in v2 but are not exposed by the installer — users can switch via the web UI if they want to experiment.

## Setup Wizard

v2 introduced a first-run `/decypharr/setup` page. It fires whenever `SetupComplete()` fails — i.e. no valid debrid/usenet provider, or `download_folder` unset. Behavior under Swizzin:

- **Zurg path**: the installer pre-populates the Real-Debrid API key from the running Zurg config, so the wizard is skipped and the UI loads directly.
- **No-zurg path**: the generated `config.json` has an empty `api_key`, so Decypharr redirects to `/decypharr/setup` on first visit. User fills in the API key (and optionally flips on Usenet), saves, done.

This is intentional — v2's `Validate()` requires at least one working debrid or usenet provider before it'll serve the main UI.

## Watchdog

`watchdog/decypharr-watchdog.sh` tails the app log and looks for `no debrid clients available`. When that pattern appears five times in a five-minute window, it restarts the service. State is kept under `/var/lib/watchdog/decypharr.state`; logs at `/var/log/watchdog/decypharr.log`.

Install / remove:

```bash
bash watchdog/decypharr-watchdog.sh --install
bash watchdog/decypharr-watchdog.sh --status
bash watchdog/decypharr-watchdog.sh --remove
```

The error pattern has survived into v2 (lives at `pkg/manager/processor.go`) so the watchdog needs no changes on upgrade.

## Upgrading from v1 (Fenrir rewrite)

v2 is a major rewrite but the binary is configured for drop-in upgrades:

- **Config schema auto-migrates on first start.** Deprecated v1 keys (`qbittorrent.download_folder`, `rclone.enabled`, `discord_webhook_url`) are mapped to the v2 equivalents (`download_folder`, `mount.rclone.*`, `notifications.webhook_url`) and the migrated config is written back.
- **Dropped keys get silently ignored**: `repair.zurg_url`, `debrid[].use_webdav`, the standalone top-level `rclone` block — all gone. Functionality preserved via the new `mount.type` abstraction.
- **`bash decypharr.sh --update`** swaps the binary + restarts the service — v2's migration then runs on start. The nginx schema auto-refresh kicks in at the top of the update path.
- **`bash decypharr.sh --update --full`** re-runs the install path, regenerating `config.json` in the clean v2 schema. Preserves the mount path (from swizdb) and the Real-Debrid key (re-read from zurg if present).

### What you lose

- **armv6 / armhf** — upstream dropped that release build at v2.0. The installer emits a clear error on `armhf`.
- **Zurg-specific repair false-positive mitigations** — the fork's zurg-path repair patches (rate-limit, HEAD-vs-GET, URL encoding) became moot when v2 rewrote the repair pipeline and removed the `zurg_url` code path entirely. If zurg-mounted items show as broken after v2, report upstream rather than patching the fork.

## Related Scripts

- `zurg.sh` — Real-Debrid WebDAV + rclone mount (common upstream data source)
- `arr-symlink-import.sh` — converts zurg-mount symlinks into hardlinks/copies for Sonarr/Radarr import
- `nzbdav.sh` — similar pattern for Usenet
