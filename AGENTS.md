# AGENTS.md

Swizzin installer scripts - bash installation scripts for integrating applications into the [Swizzin](https://swizzin.ltd/) self-hosted media server management platform.

## Quick Reference

| Task                        | Documentation                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Create a new installer      | Use the `/new-installer` skill, or start with a [template](docs/templates.md) manually                        |
| Understand script structure | [Architecture](docs/architecture.md)                                                                          |
| Code style questions        | [Coding Standards](docs/coding-standards.md)                                                                  |
| Environment variables       | [Environment Variables](docs/environment-variables.md)                                                        |
| Update the installer skill  | [Skill Maintenance](docs/skill-maintenance.md)                                                                |

## App-Specific Documentation

- [Docker Apps](docs/apps/docker-apps.md) - Lingarr, LibreTranslate, MDBListarr, StremThru, MediaFusion, Zilean, NzbDAV, Remux
- [Media Servers](docs/apps/media-servers.md) - Plex, Emby, Jellyfin subdomain scripts
- [Plex Tunnel](docs/apps/plex-tunnel.md) - Plex with VPN tunnel (Hetzner bypass)
- [Organizr](docs/apps/organizr.md) - SSO gateway
- [Multi-Instance](docs/apps/multi-instance.md) - Sonarr/Radarr instance management
- [Newtarr](docs/apps/newtarr.md) - ElfHosted Huntarr fork (media library search)
- [Zurg](docs/apps/zurg.md) - Real-Debrid WebDAV + rclone

## Subsystems

- [Backup System](docs/subsystems/backup.md) - BorgBackup with `--verify` and weekly integrity checks
- [Disaster Recovery](docs/subsystems/disaster-recovery.md) - Bare-metal restore runbook (Hetzner rescue → MD/partitions → borg extract → grub)
- [Update System](docs/subsystems/update-system.md) - `--update` flag with rollback
- [Watchdog](docs/subsystems/watchdog.md) - Health monitoring for Emby, Plex, Jellyfin
- [App Info Tool](docs/subsystems/app-info.md) - swizzin-app-info utility

## Shared Libraries

| Library | Purpose |
| --- | --- |
| `lib/nginx-utils.sh` | Validated nginx reload (`_reload_nginx`) |
| `lib/utils.sh` | Sed escape for safe substitution (`_sed_escape_value`) |
| `lib/notifications.sh` | Discord/Pushover/Notifiarr/email notifications + rate limiting |
| `lib/prowlarr-utils.sh` | Auto-configure Prowlarr Torznab indexers (`_add_prowlarr_torznab`) |

## Testing

No automated tests. Scripts must be tested on a Swizzin-installed system.

```bash
bash plex.sh                                          # Interactive
PLEX_DOMAIN="plex.example.com" bash plex.sh --subdomain  # Automated
```
