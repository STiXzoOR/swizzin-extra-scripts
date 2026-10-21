# Media Server Subdomain Scripts

plex.sh, emby.sh, and jellyfin.sh follow a common pattern for subdomain conversion. silo.sh is a separate Docker installer; see [Silo](#silo).

## Common Behavior

- Install app via `box install <app>` if not installed
- Convert from subfolder (`/<app>`) to dedicated subdomain
- Request Let's Encrypt certificate via `box install letsencrypt`
- Backup original nginx config to `/opt/swizzin-extras/<app>-backups/`
- Update panel meta with `baseurl = None` and `urloverride` in `/opt/swizzin/core/custom/profiles.py`
- Add `Content-Security-Policy: frame-ancestors` header for Organizr embedding (if configured)
- Exclude app from Organizr SSO protection

## Ports

| App      | Port  | Protocol |
| -------- | ----- | -------- |
| Plex     | 32400 | HTTP     |
| Emby     | 8096  | HTTP     |
| Jellyfin | 8922  | HTTPS    |

## Nginx Features

### Plex

- X-Plex-\* proxy headers
- `/library/streams/` location for direct streaming

### Emby

- Range/If-Range headers for streaming
- Premiere bypass (see below)
- `emby-server.service.d/analyze.conf` drop-in: `ExecStartPre` runs a full `ANALYZE` on `library.db` before every start. Emby's shutdown `pragma optimize` writes sampled planner stats that make searches take minutes on large libraries, hanging all clients. Installed on any install/subdomain run; removed by `--remove`.

### Jellyfin

- WebSocket `/socket` location
- WebOS CORS headers
- Range/If-Range headers
- `/metrics` with private network ACL

---

## Emby Premiere Bypass

emby.sh includes optional Premiere bypass functionality.

### Usage

```bash
bash emby.sh --premiere           # Enable Premiere bypass
bash emby.sh --premiere --revert  # Disable Premiere bypass
```

### How It Works

1. Retrieves Emby ServerId from API or config file
2. Computes Premiere key: `MD5("MBSupporter" + serverId + "Ae3#fP!wi")`
3. Generates self-signed SSL cert for `mb3admin.com`
4. Adds cert to system CA trust (`/usr/local/share/ca-certificates/`)
5. Creates nginx site with validation endpoints returning success responses
6. Patches `/etc/hosts` to redirect `mb3admin.com` to localhost

### Key Files

| Path                                            | Purpose                 |
| ----------------------------------------------- | ----------------------- |
| `/etc/nginx/ssl/mb3admin.com/`                  | Self-signed certificate |
| `/usr/local/share/ca-certificates/mb3admin.crt` | CA trust entry          |
| `/etc/nginx/sites-available/mb3admin.com`       | Validation nginx site   |
| `/etc/hosts.emby-premiere.bak`                  | Hosts file backup       |

### Endpoints Handled

- `/admin/service/registration/validateDevice`
- `/admin/service/registration/validate`
- `/admin/service/registration/getStatus`
- `/admin/service/appstore/register`
- `/emby/Plugins/SecurityInfo`

---

## Silo

`silo.sh` is a Docker installer, not a `box install` wrapper, and is subdomain-only (upstream recommends a dedicated hostname and has no base-path setting).

| Item | Value |
| ---- | ----- |
| Stack | `ghcr.io/silo-server/silo-server:latest` + `pgvector/pgvector:pg18` + `redis:alpine` in `/opt/silo` |
| Ports | web, Jellyfin compat and Audiobookshelf compat on allocated `127.0.0.1` ports (swizdb `silo/port`, `silo/jf_port`, `silo/abs_port`) |
| Secrets | `/opt/silo/.env` (600): `SECRET_KEY`, `POSTGRES_PASSWORD` |
| Admin | `/opt/silo/.admin_credentials` (600) |

- **Setup is first-come.** `POST /api/v2/auth/setup` has no secret, so the installer claims the admin before the vhost exists, and aborts rather than exposing an unclaimed server.
- **Settings writes need `If-Match`.** `PUT /api/v2/admin/settings` takes the ETag from `GET /api/v2/admin/settings`; the per-key route returns 404 for unset keys.
- **PostgreSQL tuning.** Silo tunes PostgreSQL itself via `ALTER SYSTEM`, but only when `POSTGRES_TUNE=auto` is in its environment. Its default memory budget is 75% of the host's RAM, so the installer pins `POSTGRES_TUNE_MEMORY` and `POSTGRES_TUNE_CPUS` to the postgres container's limits and restarts postgres once after the first boot (`shared_buffers` needs a restart).
- **Port 8096.** The Jellyfin compat listener defaults to 8096, the Emby/Jellyfin port, so the host side is remapped.
- **Client apps.** Jellyfin/Emby clients talk to the compat listener, not the web UI. `--jf-subdomain` (or `SILO_JF_DOMAIN`) gives it its own vhost (`/etc/nginx/sites-available/silo-jf`) and certificate, and sets `jellyfin_compat.public_url`; `--revert` removes it. Upstream recommends one hostname per published listener.
- **Autopulse / Autoscan.** Silo accepts the stock `jellyfin` target on its Jellyfin compat port (`POST /Library/Media/Updated`, `X-Emby-Token: sa_...` admin API key), so an existing arr → Autopulse pipeline can feed Silo with one extra target and no new arr webhooks.
- **No libraries are created.** A first scan of a large network or FUSE-backed library is heavy; add folders deliberately in the web UI.
- **`SECRET_KEY` must be backed up separately.** Losing it makes every encrypted secret unrecoverable.
