# Service Watchdog

A cron-based monitoring system that checks service health and automatically restarts unhealthy services with cooldown protection and notification rate limiting.

## Directory Structure

```
watchdog/
├── watchdog.sh               # Generic watchdog engine
├── emby-watchdog.sh          # Emby installer/manager
├── plex-watchdog.sh          # Plex installer/manager
├── jellyfin-watchdog.sh      # Jellyfin installer/manager
└── configs/
    ├── watchdog.conf.example            # Global config template
    ├── emby-watchdog.conf.example       # Emby config template
    ├── plex-watchdog.conf.example       # Plex config template
    └── jellyfin-watchdog.conf.example   # Jellyfin config template
```

## Supported Services

| Service    | Health Endpoint                               | Expected Response  |
| ---------- | --------------------------------------------- | ------------------ |
| Emby       | `http://127.0.0.1:8096/emby/System/Info/Public` | `ServerName`    |
| Plex       | `http://127.0.0.1:32400/identity`             | `MediaContainer`   |
| Jellyfin   | `http://127.0.0.1:8096/health`                | `Healthy`          |

## Usage

```bash
bash watchdog/emby-watchdog.sh              # Interactive setup
bash watchdog/emby-watchdog.sh --install    # Install watchdog for Emby
bash watchdog/emby-watchdog.sh --remove     # Remove watchdog for Emby
bash watchdog/emby-watchdog.sh --status     # Show current status
bash watchdog/emby-watchdog.sh --reset      # Clear backoff state, resume monitoring

# Same flags for plex-watchdog.sh and jellyfin-watchdog.sh
```

## How It Works

1. Cron runs `watchdog.sh` every 2 minutes
2. Checks if process is running (`systemctl is-active`)
3. Checks HTTP health endpoint (validates HTTP status 200-399 + optional body match)
4. If unhealthy, restarts service (max 3 restarts per 15 minutes)
5. Sends notifications via shared `lib/notifications.sh` (Discord, Pushover, Notifiarr, email)
6. Rate-limits notifications (max 1 per 5 minutes per service via `_should_notify()`)
7. Enters backoff mode if max restarts reached
8. Detects manual restarts and clears backoff automatically

## Runtime Files

| File                                          | Purpose                                 |
| --------------------------------------------- | --------------------------------------- |
| `/opt/swizzin-extras/watchdog.sh`             | Engine script                           |
| `/opt/swizzin-extras/watchdog.conf`           | Global config (notifications, defaults) |
| `/opt/swizzin-extras/watchdog.d/<svc>.conf`   | Service-specific config                 |
| `/var/log/watchdog/<svc>.log`                 | Log file                                |
| `/var/lib/watchdog/<svc>.state`               | State (restart counts, backoff)         |
| `/var/lib/watchdog/<svc>.notify_ts`           | Last notification timestamp (rate limit)|
| `/var/lib/watchdog/<svc>.lock`                | Lock file (prevents concurrent runs)    |
| `/etc/cron.d/<svc>-watchdog`                  | Cron job                                |

State is stored in `/var/lib/watchdog/` (persistent across reboots), not `/var/run/` (tmpfs).

## Adding New Services

Create a new wrapper script (copy any existing `*-watchdog.sh`) and adjust:

- `SERVICE_NAME` - systemd service name (e.g., `plexmediaserver`)
- `APP_NAME` - display name for notifications (e.g., `Plex`)
- `HEALTH_URL` - HTTP endpoint to check
- `HEALTH_EXPECT` - Expected string in response body (optional)
