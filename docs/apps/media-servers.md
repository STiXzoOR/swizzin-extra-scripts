# Media Server Subdomain Scripts

plex.sh, emby.sh, and jellyfin.sh follow a common pattern for subdomain conversion.

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
