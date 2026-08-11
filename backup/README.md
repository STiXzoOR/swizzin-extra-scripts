# Complete Borg Backup Setup Guide

## For Swizzin + STiXzoOR Custom Scripts

---

## Supported Backup Targets

This backup system works with any SSH-accessible borg repository:

| Provider                | Notes                                                        |
| ----------------------- | ------------------------------------------------------------ |
| **Hetzner Storage Box** | Port 23, `borg-1.4` remote path, `install-ssh-key` supported |
| **Rsync.net**           | Standard SSH, `borg1` remote path                            |
| **BorgBase**            | Standard SSH, append-only available, `borg` remote path      |
| **Self-hosted**         | Any Linux server with borg installed (NAS, VPS, dedicated)   |

---

## Supported Applications

### Official Swizzin Apps

| Category            | Applications                                                                                        |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| **Automation**      | autobrr, autodl, bazarr, lidarr, medusa, mylar, ombi, sickchill, sickgear, sonarr, radarr, prowlarr |
| **Media Servers**   | airsonic, calibre-web, emby, jellyfin, mango, navidrome, plex, tautulli                             |
| **Torrent Clients** | deluge, flood, qbittorrent, rtorrent, rutorrent, transmission                                       |
| **Usenet**          | nzbget, sabnzbd, nzbhydra, nzbhydra2                                                                |
| **Indexers**        | jackett                                                                                             |
| **Web/Utils**       | nginx, organizr, panel, filebrowser, netdata, syncthing, nextcloud, wireguard                       |

### STiXzoOR Custom Apps (github.com/STiXzoOR/swizzin-scripts)

| App                            | Description                            |
| ------------------------------ | -------------------------------------- |
| **sonarr-\*/radarr-\***        | Multi-instance (4k, anime, kids, etc.) |
| **overseerr/jellyseerr/seerr** | Media request management               |
| **zurg**                       | Real-Debrid WebDAV with rclone mount   |
| **decypharr**                  | Encrypted file/torrent management      |
| **notifiarr**                  | Notification relay for \*arr apps      |
| **byparr/flaresolverr**        | Cloudflare bypass for indexers         |
| **huntarr**                    | Automated media discovery              |
| **subgen**                     | Whisper AI subtitle generation         |
| **cleanuparr**                 | Download queue cleanup                 |
| **stremthru**                  | Debrid streaming proxy (SQLite)        |
| **aiostreams**                 | Stremio super-addon (dotenv + JSON state) |
| **remux**                      | Jellyfin-compatible media server (SQLite) |
| **mediafusion**                | Stremio add-on + Torznab (Postgres)    |
| **zilean**                     | DMM hashlist Torznab indexer (Postgres) |
| **nzbdav**                     | NZB-to-WebDAV bridge (SQLite)          |
| **nzbhydra2**                  | Newznab meta-indexer (YAML + SQLite)   |
| **easynews-indexer**           | Easynews → Newznab bridge (stateless; .env only) |
| **newtarr**                    | Media library search tool              |
| **autopulse**                  | Media server library notifier (SQLite) |
| **babysitarr**                 | Arr/RD self-healing daemon (.env + state JSON) |

---

## What Gets Backed Up

| Category               | Paths                                  | Notes                                                              |
| ---------------------- | -------------------------------------- | ------------------------------------------------------------------ |
| **App configs**        | `~/.config/<App>/`                     | Databases, config.xml, etc.                                        |
| **App auto-backups**   | `Backups/`, `backup/`, `backups/` dirs | Built-in scheduled backups (Sonarr, Radarr, Bazarr, Huntarr, etc.) |
| **Zurg critical data** | `config.yml`, `data/*.zurgtorrent`     | Your library metadata                                              |
| **Symlinks**           | `/mnt/symlinks/`                       | Arr root folder symlinks                                           |
| **System**             | `/etc/`, `/root/`, cron                | System configuration                                               |
| **Swizzin**            | `/etc/swizzin/`, `/install/`           | Lock files, scripts                                                |
| **Nginx/SSL**          | `/etc/nginx/`, `/etc/letsencrypt/`     | Reverse proxy configs                                              |
| **STiXzoOR extras**    | `/opt/swizzin-extras/`                 | Watchdog, SSO configs                                              |

**Estimated total: ~5-15 GB** (after deduplication)

## What Gets Excluded

| Category                | Path                                                           | Size         |
| ----------------------- | -------------------------------------------------------------- | ------------ |
| **Zurg data directory** | `~/.config/zurg/data/` (except `*.zurgtorrent`)                | Up to 256 GB |
| **Remote mounts**       | `/mnt/zurg/`, `/mnt/remote/`                                   | N/A          |
| **Logs**                | All `*/logs/` directories                                      | 1-5 GB       |
| **Transcodes**          | Emby/Jellyfin/Plex temp                                        | 10-100 GB    |
| **MediaCover**          | Poster images                                                  | 0.5-2 GB     |
| **App binaries**        | `/opt/Sonarr/`, `/opt/huntarr/` (except `data/backups/`), etc. | 2-5 GB       |

---

## Quick Start

### Option A: Automated Setup (Recommended)

Run the interactive setup wizard:

```bash
bash swizzin-backup-install.sh
```

The wizard walks through all 10 steps automatically and supports any SSH-accessible borg server.

### Option B: Manual Setup

#### 1. Choose Backup Target

Select a backup destination:

- **Hetzner Storage Box**: [hetzner.com/storage/storage-box](https://www.hetzner.com/storage/storage-box) — Enable SSH in console
- **Rsync.net**: [rsync.net/products/attic.html](https://www.rsync.net/products/attic.html)
- **BorgBase**: [borgbase.com](https://www.borgbase.com/)
- **Self-hosted**: Any Linux server with borg installed

#### 2. SSH Key Setup

```bash
# Generate key
ssh-keygen -t ed25519 -f ~/.ssh/id_backup -C "backup@$(hostname)" -N ""

# Add to remote server (method varies by provider)
# Hetzner: cat ~/.ssh/id_backup.pub | ssh -p23 uXXXXX@uXXXXX.your-storagebox.de install-ssh-key
# Others: Add public key to ~/.ssh/authorized_keys manually

# Test connection
ssh -p<PORT> -i ~/.ssh/id_backup user@hostname ls -la
```

#### 3. Install Borg

```bash
apt update && apt install -y borgbackup
```

#### 4. Create Passphrase

```bash
openssl rand -base64 32 > /root/.swizzin-backup-passphrase
chmod 600 /root/.swizzin-backup-passphrase
cat /root/.swizzin-backup-passphrase  # SAVE THIS!
```

#### 5. Initialize Repository

```bash
export BORG_RSH='ssh -p<PORT> -i ~/.ssh/id_backup'
export BORG_PASSCOMMAND='cat /root/.swizzin-backup-passphrase'

# Adjust --remote-path for your provider (borg-1.4, borg1, borg, etc.)
borg init --encryption=repokey-blake2 --remote-path=borg \
    ssh://user@hostname:port/./path/to/repo

# Export key - SAVE THIS TOO!
borg key export ssh://user@hostname:port/./path/to/repo \
    /root/swizzin-backup-key-export.txt
```

#### 6. Install Config

```bash
cp swizzin-backup.conf /etc/swizzin-backup.conf
chmod 600 /etc/swizzin-backup.conf
```

Edit `/etc/swizzin-backup.conf` and set:

- `BORG_REPO` — your repository URL
- `BORG_RSH` — SSH command with port and key path
- `BORG_REMOTE_PATH` — remote borg binary (varies by provider)
- `SWIZZIN_USER` — your Swizzin username
- `HC_UUID` — Healthchecks.io UUID (optional)
- Notification settings (optional, see [Notifications](#notifications))

#### 7. Install Scripts

```bash
cp swizzin-backup.sh /usr/local/bin/ && chmod +x /usr/local/bin/swizzin-backup.sh
cp swizzin-restore.sh /usr/local/bin/ && chmod +x /usr/local/bin/swizzin-restore.sh
cp swizzin-excludes.txt /etc/
cp swizzin-backup.service swizzin-backup.timer /etc/systemd/system/
cp swizzin-backup-logrotate /etc/logrotate.d/swizzin-backup
```

#### 8. Test

```bash
# Verify config loads correctly
swizzin-backup.sh --services

# Dry run — shows what would be backed up
swizzin-backup.sh --dry-run

# Full backup
swizzin-backup.sh
```

#### 9. Enable Automation

```bash
systemctl daemon-reload
systemctl enable --now swizzin-backup.timer
systemctl list-timers | grep swizzin
```

---

## CLI Usage

### Backup Script

```bash
swizzin-backup.sh                # Run full backup (default)
swizzin-backup.sh --dry-run      # Show what would be backed up
swizzin-backup.sh --list         # List archives
swizzin-backup.sh --info         # Show repository info
swizzin-backup.sh --check        # Run borg check
swizzin-backup.sh --services     # List discovered services and their state
swizzin-backup.sh --help         # Show help
```

### Progress Feedback

The backup script provides real-time progress visibility across all three phases:

```
[2026-01-26 20:15:13] Phase 1/3: Creating backup archive...
[2026-01-26 20:16:13]   ... backup in progress (1m elapsed)
[2026-01-26 20:17:13]   ... backup in progress (2m elapsed)
[2026-01-26 20:17:45] Phase 1/3: Archive created (2m 32s)
[2026-01-26 20:17:45] Phase 2/3: Pruning old archives...
[2026-01-26 20:18:10] Phase 2/3: Prune complete (25s)
[2026-01-26 20:18:10] Phase 3/3: Compacting repository...
[2026-01-26 20:18:22] Phase 3/3: Compact complete (12s)
```

**Heartbeat interval:** During `borg create` (the longest phase), a background heartbeat logs elapsed time at a configurable interval. Set `PROGRESS_INTERVAL` in `/etc/swizzin-backup.conf` (default: 60 seconds, 0 to disable).

**Interactive progress bar:** When run manually from a terminal, the script automatically enables borg's `--progress` flag, which displays a real-time progress bar with file count, data rate, and ETA. In non-interactive mode (cron/systemd), verbose file listing is streamed to the log instead.

### Restore Script

```bash
swizzin-restore.sh               # Interactive restore menu
swizzin-restore.sh --list        # List archives
swizzin-restore.sh --app sonarr  # Restore Sonarr config
swizzin-restore.sh --app radarr-4k  # Restore multi-instance
swizzin-restore.sh --mount       # FUSE mount for browsing
swizzin-restore.sh --extract     # Extract specific path to staging dir
swizzin-restore.sh --help        # Show help and known apps
```

---

## /mnt/symlinks Backup

The script explicitly includes `/mnt/symlinks` in the backup, which contains your arr apps' root folder symlinks. This is **critical** for Real-Debrid setups where Sonarr/Radarr point to symlinked content.

These symlinks are small but essential — losing them means reconfiguring all your arr apps' root folders.

---

## Notifications

All configured notification providers fire simultaneously on backup start, success, warning, and failure.

### Configuration

Edit `/etc/swizzin-backup.conf` and set any combination:

```bash
# Discord webhook URL
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# Pushover (both required)
PUSHOVER_USER="your-user-key"
PUSHOVER_TOKEN="your-app-token"

# Notifiarr passthrough API key
NOTIFIARR_API_KEY="your-api-key"

# Email (requires sendmail or mail command on system)
EMAIL_TO="admin@example.com"
```

### Notification Events

| Event                  | Level   | When                                   |
| ---------------------- | ------- | -------------------------------------- |
| Backup started         | info    | Before service stop                    |
| Backup success         | info    | After prune + compact, includes stats  |
| Backup warning         | warning | Borg exit code 1                       |
| Backup failure         | error   | Borg exit code 2+                      |
| Service restart failed | error   | One or more services failed to restart |

### Success Notification Contents

- Hostname
- Archive name
- Duration
- Original size, compressed size, deduplicated size
- Number of files

---

## Service Management

Services are stopped in dependency order (consumers first, infrastructure last) and started in reverse order. The following services are never stopped:

- `rclone-zurg` — remote filesystem must stay mounted
- `organizr` — SSO gateway
- `nextcloud` — independent service
- `nginx` — reverse proxy
- `panel` — Swizzin panel

A **cleanup trap** ensures services are restarted even if the script crashes or is killed.

### Selective Service Stopping

By default, only SQLite-backed services are stopped (`STOP_MODE="critical"`). Configure in `/etc/swizzin-backup.conf`:

| Mode       | Behavior                                       | Downtime                                        |
| ---------- | ---------------------------------------------- | ----------------------------------------------- |
| `all`      | Stop all services                              | Maximum (all apps down)                         |
| `critical` | Only stop SQLite-backed services **(default)** | Moderate (arr apps down, media servers stay up) |
| `none`     | Don't stop any services                        | None (risk of inconsistent DBs)                 |

```bash
# In /etc/swizzin-backup.conf
STOP_MODE="critical"
```

**Critical services** (stopped in `critical` mode — these use SQLite databases):

- **Arr apps**: sonarr, radarr, lidarr, prowlarr, bazarr
- **Automation**: autobrr, medusa, mylar, sickchill, sickgear
- **Indexers**: jackett, nzbhydra
- **Request management**: overseerr, jellyseerr, seerr, ombi
- **Monitoring**: tautulli
- **Debrid indexers**: stremthru, nzbdav (SQLite databases)

**Non-critical services** (keep running in `critical` mode):

- Media servers: emby, jellyfin, plex, airsonic, calibreweb, mango, navidrome
- Download clients: deluge, flood, qbittorrent, rtorrent, transmission, nzbget, sabnzbd
- Helpers: huntarr, cleanuparr, notifiarr, decypharr, byparr, flaresolverr
- Debrid indexers: mediafusion, zilean (Postgres-backed, no SQLite)
- Utilities: filebrowser, syncthing, pyload, netdata, subgen, newtarr, zurg

> **Note:** Apps with built-in automated backups (Sonarr, Radarr, Bazarr, Huntarr, Tautulli, etc.) create periodic ZIP/DB snapshots that are included in the borg backup. These provide an extra recovery point even if the live database is slightly inconsistent.

### View Service Order

```bash
swizzin-backup.sh --services
```

---

## Retention Policy

| Keep    | Default | Purpose           |
| ------- | ------- | ----------------- |
| Daily   | 7       | Recent recovery   |
| Weekly  | 4       | ~1 month coverage |
| Monthly | 6       | ~6 month history  |
| Yearly  | 2       | Long-term archive |

Customize in `/etc/swizzin-backup.conf`:

```bash
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=2
```

---

## Useful Commands

```bash
# Manual backup
swizzin-backup.sh

# List archives
swizzin-backup.sh --list

# Repository info
swizzin-backup.sh --info

# Integrity check
swizzin-backup.sh --check

# Interactive restore
swizzin-restore.sh

# Restore single app
swizzin-restore.sh --app sonarr

# Mount and browse
swizzin-restore.sh --mount

# View logs
journalctl -u swizzin-backup.service -n 100
tail -f /var/log/swizzin-backup.log
```

---

## Troubleshooting

### Multi-instance not detected

```bash
swizzin-backup.sh --services
systemctl list-units --type=service | grep -E "(sonarr|radarr)-"
ls -la /install/.sonarr-*.lock /install/.radarr-*.lock
```

### Zurg cache still backing up

```bash
# Find actual cache path (replace <user> with your Swizzin username)
find /home/<user> -name "rclone-cache" -type d 2>/dev/null
# Update /etc/swizzin-excludes.txt accordingly
```

### Service won't restart

```bash
systemctl status sonarr@<user>
journalctl -u sonarr@<user> -n 50
```

### Services stuck after failed backup

The cleanup trap handles this automatically. If services are still down:

```bash
# Check for stale stopped-services file
cat /var/run/swizzin-stopped-services.txt
# Manually restart
while read -r svc; do systemctl start "$svc"; done < /var/run/swizzin-stopped-services.txt
rm /var/run/swizzin-stopped-services.txt
```

---

## Security

### Append-only mode (ransomware protection)

Configure your backup server's `~/.ssh/authorized_keys` to restrict the backup key:

```
command="borg serve --append-only --restrict-to-path /./path/to/repo",restrict ssh-ed25519 AAAA...
```

This prevents attackers from deleting existing backups. Run `borg prune` from a separate trusted machine.

**Provider-specific notes:**

- **Hetzner Storage Box**: Edit via `ssh -p23 user@host vi .ssh/authorized_keys`
- **BorgBase**: Append-only mode available in dashboard
- **Self-hosted**: Edit `~/.ssh/authorized_keys` directly

### Config file permissions

```bash
chmod 600 /etc/swizzin-backup.conf
chmod 600 /root/.swizzin-backup-passphrase
```

### Store credentials externally

Keep passphrase + key export in a password manager!
