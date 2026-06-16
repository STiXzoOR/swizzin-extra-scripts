# Newtarr

Neutered fork of Huntarr v6.6.3 maintained by [ElfHosted](https://github.com/elfhosted/newtarr). Continuously searches *arr media libraries (Sonarr, Radarr, Lidarr, Readarr, Whisparr) for missing content and quality upgrades.

## Install

```bash
bash newtarr.sh
```

Environment variables for unattended install: none required.

## Usage

```bash
bash newtarr.sh --update             # Smart update (git pull + uv sync)
bash newtarr.sh --update --full      # Full reinstall from scratch
bash newtarr.sh --update --verbose   # Update with verbose logging
bash newtarr.sh --remove             # Remove (prompts to purge config)
bash newtarr.sh --remove --force     # Remove even if lock file missing
bash newtarr.sh --register-panel     # Re-register with Swizzin panel
```

## Key Files

| Path                               | Purpose                    |
| ---------------------------------- | -------------------------- |
| `/opt/newtarr/`                    | Application directory      |
| `~/.config/Newtarr/`              | Config directory (JSON)    |
| `~/.config/Newtarr/env.conf`      | Environment file           |
| `/etc/systemd/system/newtarr.service` | Systemd unit            |
| `/etc/nginx/apps/newtarr.conf`    | Nginx reverse proxy config |

## Port

Dynamically assigned from range 10000-12000 at install time. Stored in the systemd unit as `Environment=PORT=<port>`.

## Nginx

Reverse-proxied at `/<hostname>/newtarr/` with HTTP basic auth. The `/api` path also requires auth to prevent unauthenticated API access.

## Differences from Huntarr

- Maintained fork (Huntarr upstream repo was deleted)
- No known unpatched security vulnerabilities
- Cloned from `elfhosted/newtarr` instead of `plexguide/Huntarr.io`
- Same Python/Flask/Waitress stack, same web UI on port 9705 (overridden by `PORT` env var)

## Related Scripts

- `huntarr.sh` - Original Huntarr installer (has security warnings)
