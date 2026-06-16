# Update System

Unified update mechanism for swizzin installer scripts.

## Overview

All scripts support `--update` flag with consistent behavior across app types:

| App Type | Default Update        | Full Reinstall     |
| -------- | --------------------- | ------------------ |
| Binary   | Replace binary        | Re-run install     |
| Python   | git pull + uv sync    | Re-clone + install |
| Docker   | Pull image + recreate | N/A                |

## Flags

| Flag                 | Description                              |
| -------------------- | ---------------------------------------- |
| `--update`           | Perform update (behavior varies by type) |
| `--update --full`    | Full reinstall (binary/python only)      |
| `--update --verbose` | Show detailed progress                   |

## Rollback System

Binary and Python apps include automatic rollback:

1. Backup created before update starts
2. Service stopped
3. Update performed
4. Service restarted and verified
5. On failure: restore from backup
6. On success: cleanup backup

**Backup location:** `/tmp/swizzin-update-backups/{app_name}/`

## Implementation

### Binary Apps

Uses GitHub releases API to download latest version:

- Queries `api.github.com/repos/{owner}/{repo}/releases/latest`
- Downloads architecture-specific binary
- Extracts and replaces existing binary

### Python Apps

Uses git and uv for updates:

- `git pull` to fetch latest code
- `uv sync` to update dependencies
- Runs as application user to preserve permissions

### Docker Apps

Uses Docker Compose for updates:

- `docker compose pull` to fetch latest image
- `docker compose up -d` to recreate container
- `docker image prune -f` to cleanup old images

## Scripts with Update Support

### Binary Apps

- notifiarr.sh
- decypharr.sh
- cleanuparr.sh
- flaresolverr.sh
- zurg.sh (also supports `--latest` and `ZURG_VERSION_TAG`)

### Python Apps

- huntarr.sh
- byparr.sh
- subgen.sh

### Docker Apps

- lingarr.sh
- libretranslate.sh
