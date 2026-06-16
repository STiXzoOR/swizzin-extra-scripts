# Maintenance Checklist

When adding a new installer script to this repository:

## 1. Create the Installer Script

Use the appropriate template from `templates/`:

- `template-binary.sh` for single binaries
- `template-python.sh` for Python/uv apps
- `template-docker.sh` for Docker Compose apps
- `template-subdomain.sh` for extended installers
- `template-multiinstance.sh` for instance managers

## 2. Update swizzin-app-info

Add an entry to the `APP_CONFIGS` dictionary:

```python
"myapp": {
    "config_paths": ["/home/{user}/.config/Myapp/config.xml"],
    "format": "xml",  # or json, yaml, ini, toml, php, dotenv, docker_compose
    "keys": {
        "port": "Port",
        "baseurl": "UrlBase",
        "apikey": "ApiKey"
    },
    "default_port": 8080  # optional fallback
}
```

Then update the installed copy:

```bash
cp swizzin-app-info /usr/local/bin/swizzin-app-info
```

## 3. Update Backup System

### backup/swizzin-backup.sh

Add to these arrays:

- `SERVICE_TYPES` - App with type (`"user"` for `@user` template, `"system"` for plain service)
- `SERVICE_NAME_MAP` - If systemd service name differs from app name (e.g., `["emby"]="emby-server"`)
- `SERVICE_STOP_ORDER` - Position in stop order (downstream consumers first, infrastructure last)
- `SERVICE_STOP_CRITICAL` - If app uses SQLite and needs stopping for consistent backup

### backup/swizzin-restore.sh

Mirror the above, plus:

- `APP_PATHS` - Config/data directory path (use `home/*/.config/AppName` pattern)

### backup/swizzin-excludes.txt

Add exclusion patterns for logs, caches, temp files, docker-compose.yml (recreated by installer), and reinstallable code (.git, .venv, node_modules).

### backup/README.md

Add to Supported Applications table.

### Update installed copies

After updating backup files, copy them to the server:

```bash
cp backup/swizzin-backup.sh /usr/local/bin/swizzin-backup.sh
cp backup/swizzin-restore.sh /usr/local/bin/swizzin-restore.sh
cp backup/swizzin-excludes.txt /etc/swizzin-excludes.txt
```

## 4. Update README.md

Add entry to:

- Available Scripts table
- Detailed documentation section (if needed)

## 5. Update AGENTS.md

Add to:

- Files overview in [docs/architecture.md](architecture.md)
- App-specific documentation if complex enough to warrant its own section

## 6. Shared Libraries

If the new script uses nginx, source `lib/nginx-utils.sh` for validated reload:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/nginx-utils.sh"
```

If the script uses `sed` with user-supplied values, source `lib/utils.sh` for `_sed_escape_value()`.

If adding a new watchdog, the notification functions are in `lib/notifications.sh` (shared by all watchdog and backup scripts).

## 7. Update Testing

When implementing `--update` for a new script:

- [ ] Test `--update` updates the application correctly
- [ ] Test `--update --full` performs complete reinstall
- [ ] Test `--update --verbose` shows detailed output
- [ ] Test rollback triggers on simulated failure (e.g., stop service before update completes)
- [ ] Verify backup is cleaned up after successful update
