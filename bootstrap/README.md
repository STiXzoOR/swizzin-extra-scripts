# Swizzin Server Bootstrap

Automated bootstrapping script for preparing a fresh Ubuntu server for streaming and media management with Swizzin.

## Features

- **Security Hardening**
  - SSH key-only authentication with custom port
  - fail2ban with SSH protection
  - UFW firewall configuration
  - Unattended security updates

- **Performance Tuning**
  - TCP BBR congestion control
  - Optimized buffer sizes for streaming
  - Increased file descriptor limits
  - FUSE optimization for rclone mounts

- **Application Management**
  - Interactive app selection with preset bundles
  - Multi-instance support for Sonarr/Radarr/Bazarr
  - Subdomain configuration for media servers
  - Automatic installation order enforcement

- **Notifications**
  - Pushover integration
  - System reboot notifications
  - APT update notifications

## Requirements

- Fresh Ubuntu 22.04 or 24.04 installation
- Root access
- Internet connectivity
- SSH public key for authentication

## Quick Start

```bash
# Clone the repository
git clone https://github.com/STiXzoOR/swizzin-scripts.git
cd swizzin-scripts/bootstrap

# Run the bootstrap
sudo bash bootstrap.sh
```

## Usage

### Full Bootstrap (Interactive)

```bash
sudo bash bootstrap.sh
```

This runs the complete bootstrap process:

1. Pre-flight validation
2. SSH hardening
3. fail2ban configuration
4. UFW firewall setup
5. Kernel tuning
6. Swizzin installation
7. Application installation
8. Notification setup

### Module-Specific Commands

```bash
# Security hardening only
sudo bash bootstrap.sh --hardening

# Kernel tuning only
sudo bash bootstrap.sh --tuning

# App installation only
sudo bash bootstrap.sh --apps

# Notification setup only
sudo bash bootstrap.sh --notifications
```

### Restore Commands

```bash
# Interactive restore menu
sudo bash bootstrap.sh --restore

# Specific component restore
sudo bash bootstrap.sh --restore-ssh
sudo bash bootstrap.sh --restore-fail2ban
sudo bash bootstrap.sh --restore-ufw
sudo bash bootstrap.sh --restore-tuning

# Full restore to pre-bootstrap state
sudo bash bootstrap.sh --restore-all
```

### Status and Utilities

```bash
# Show current status
sudo bash bootstrap.sh --status

# List available backups
bash bootstrap.sh --list-backups

# Clean all backups
sudo bash bootstrap.sh --clean-backups
```

## App Bundles

| Bundle    | Apps                                   |
| --------- | -------------------------------------- |
| Core      | nginx, panel                           |
| Streaming | Plex, Emby, Jellyfin                   |
| Arr Stack | Sonarr, Radarr, Bazarr, Prowlarr       |
| Debrid    | Zurg, Decypharr                        |
| Helpers   | Huntarr, Cleanuparr, Byparr, Notifiarr |
| Full      | All of the above + Organizr            |

## Installation Order

Apps are installed in a specific order to handle dependencies:

1. **Swizzin Base** - nginx, panel
2. **Media Servers** - Plex, Emby, Jellyfin (in that order)
3. **Arr Stack** - Sonarr, Radarr, Bazarr, Prowlarr
4. **Debrid** - Zurg, then Decypharr
5. **Helpers** - Huntarr, Cleanuparr, Byparr, Notifiarr, Subgen
6. **Watchdog** - After media servers
7. **Organizr** - Always last (SSO gateway)

## Environment Variables

Pre-set environment variables to bypass prompts:

```bash
# SSH
SSH_PORT=2222
SSH_KEY="ssh-ed25519 AAAA..."

# Updates
REBOOT_TIME="04:00"

# Notifications
PUSHOVER_USER="your-user-key"
PUSHOVER_TOKEN="your-api-token"

# Real-Debrid (for Zurg)
RD_TOKEN="your-realdebrid-token"
ZURG_VERSION="free"  # or "paid"
GITHUB_TOKEN="ghp_..."  # for paid Zurg

# Notifiarr
DN_API_KEY="your-notifiarr-key"

# Subdomains
PLEX_DOMAIN="plex.example.com"
EMBY_DOMAIN="emby.example.com"
JELLYFIN_DOMAIN="jellyfin.example.com"
```

## Configuration File

For non-interactive deployment, copy and customize the example config:

```bash
cp configs/bootstrap.conf.example configs/bootstrap.conf
# Edit bootstrap.conf with your settings
source configs/bootstrap.conf
sudo -E bash bootstrap.sh
```

## Directory Structure

```
bootstrap/
├── bootstrap.sh           # Main entry point
├── configs/
│   └── bootstrap.conf.example
├── lib/
│   ├── common.sh         # Colors, logging, prompts
│   ├── validation.sh     # Pre-flight checks
│   ├── hardening.sh      # SSH, fail2ban, UFW
│   ├── tuning.sh         # Kernel/sysctl tuning
│   ├── restore.sh        # Restore functions
│   ├── apps.sh           # App management
│   └── notifications.sh  # Pushover setup
└── README.md
```

## Runtime Files

After bootstrap, these files are created:

| File                                       | Purpose                     |
| ------------------------------------------ | --------------------------- |
| `/opt/swizzin-extras/bootstrap.done`              | Bootstrap completion marker |
| `/opt/swizzin-extras/bootstrap.conf`              | Saved notification config   |
| `/opt/swizzin-extras/bootstrap-backups/`          | Pre-bootstrap backups       |
| `/opt/swizzin-extras/notify.sh`                   | Notification helper script  |
| `/root/logs/bootstrap.log`                 | Bootstrap log file          |
| `/etc/sysctl.d/99-streaming.conf`          | Kernel tuning               |
| `/etc/ssh/sshd_config.d/99-hardening.conf` | SSH hardening               |
| `/etc/fail2ban/jail.local`                 | fail2ban jails              |

## Kernel Tuning Details

The bootstrap applies these optimizations:

- **TCP Buffers**: Increased for high-throughput streaming
- **BBR Congestion Control**: Better performance over WAN
- **TCP Fast Open**: Reduced connection latency
- **Connection Tracking**: Increased table size for many streams
- **File Descriptors**: 1M limit for heavy concurrent use
- **inotify**: Increased watches for arr apps
- **Swappiness**: Reduced to prefer RAM over swap

## Port Conflict Resolution

When both Emby and Jellyfin are installed:

- Emby uses default ports: 8096 (HTTP), 8920 (HTTPS)
- Jellyfin uses: 8097 (HTTP), 8923 (HTTPS)

This is handled automatically by the modified `jellyfin.sh` script.

## Troubleshooting

### SSH Access Lost

If you lose SSH access after hardening:

1. Use Hetzner Robot console access
2. Run: `sudo bash bootstrap.sh --restore-ssh`
3. Reconnect via SSH on port 22

### fail2ban Blocking

Check if your IP is banned:

```bash
fail2ban-client status sshd
```

Unban an IP:

```bash
fail2ban-client set sshd unbanip <IP>
```

### UFW Issues

Reset firewall to defaults:

```bash
sudo bash bootstrap.sh --restore-ufw
```

### Full Reset

Restore all settings to pre-bootstrap state:

```bash
sudo bash bootstrap.sh --restore-all
```

## License

Part of [swizzin-scripts](https://github.com/STiXzoOR/swizzin-scripts) by STiXzoOR.
