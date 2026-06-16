# Zurg (Real-Debrid)

WebDAV server for Real-Debrid with rclone filesystem mount.

## Services

Zurg creates two systemd services:

| Service               | Purpose                                    |
| --------------------- | ------------------------------------------ |
| `zurg.service`        | The WebDAV server                          |
| `rclone-zurg.service` | The rclone filesystem mount at `/mnt/zurg` |

## Port

Fixed at 9999 (WebDAV server default).

## Key Files

| Path                           | Purpose                |
| ------------------------------ | ---------------------- |
| `/opt/zurg/`                   | Zurg binary and config |
| `/mnt/zurg/`                   | rclone mount point     |
| `~/.config/rclone/rclone.conf` | rclone configuration   |

## No Nginx

Zurg is an internal service with no nginx reverse proxy. It's accessed directly by other apps (like Plex, Sonarr, Radarr) on the local network.

## Related Scripts

- `decypharr.sh` - Uses rclone for encrypted file management
- `arr-symlink-import.sh` - Creates symlinks from Zurg mount to arr root folders
