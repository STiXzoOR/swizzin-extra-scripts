# Templates

The `templates/` directory contains starter templates for common script types.

## Available Templates

| Template                    | Use Case                                   | Examples                    |
| --------------------------- | ------------------------------------------ | --------------------------- |
| `template-binary.sh`        | Single binary apps installed to `/usr/bin` | decypharr, notifiarr        |
| `template-python.sh`        | Python apps using uv for dependencies      | byparr, huntarr, subgen     |
| `template-docker.sh`        | Docker Compose apps with systemd wrapper   | lingarr, libretranslate     |
| `template-subdomain.sh`     | Extended installers with subdomain support | plex, emby, jellyfin, panel |
| `template-multiinstance.sh` | Managing multiple instances of a base app  | sonarr, radarr              |

## Using a Template

1. Copy the appropriate template:

   ```bash
   cp templates/template-binary.sh myapp.sh
   ```

2. Search and replace the placeholder names:

   ```bash
   sed -i 's/myapp/yourapp/g; s/Myapp/Yourapp/g; s/MYAPP/YOURAPP/g' myapp.sh
   ```

3. Look for `# CUSTOMIZE:` comments and update those sections

## Customization Points

Each template marks customization points with `# CUSTOMIZE:` comments:

1. **App variables** - name, port, binary URL, icon
2. **Architecture mapping** - in `_install_<app>()`
3. **Config file format** - in `_install_<app>()`
4. **Systemd service options** - in `_systemd_<app>()`
5. **Nginx location config** - in `_nginx_<app>()`

## Template Features

All templates include:

- `set -euo pipefail` strict error handling
- Cleanup trap handler (`trap cleanup EXIT`)
- Config overwrite guards (won't clobber existing configs on re-run)
- `mktemp` for temporary files (no predictable `/tmp` paths)
- Validated nginx reload via `_reload_nginx()` from `lib/nginx-utils.sh`
- Local-first panel helper loading (no GitHub download)
- Detailed header with usage
- Standard function structure
- Inline documentation
- Coding standards already applied
- Lock file handling
- Panel registration
- Remove functionality

## Extended Installer Pattern

Scripts with subdomain support (plex.sh, emby.sh, etc.) follow this CLI pattern:

```bash
bash <app>.sh                       # Interactive setup
bash <app>.sh --subdomain           # Convert to subdomain mode
bash <app>.sh --subdomain --revert  # Revert to subfolder mode
bash <app>.sh --remove [--force]    # Complete removal
```

Key functions in extended installers:

- `_get_domain()` / `_prompt_domain()` - Domain management with swizdb persistence
- `_prompt_le_mode()` - Let's Encrypt mode selection
- `_get_install_state()` - Detect current state (not_installed, subfolder, subdomain)
- `_install_subdomain()` / `_revert_subdomain()` - Subdomain conversion
- `_interactive()` - Interactive mode entry point

## Update Mechanism

All templates support the `--update` flag for updating installed applications.

### Binary Template

- `--update` - Replace binary only (default), downloads latest from GitHub
- `--update --full` - Full reinstall (re-runs complete install process)
- `--update --verbose` - Show detailed progress

### Python Template

- `--update` - Smart update: `git pull` + `uv sync` (default)
- `--update --full` - Full reinstall (removes directory, re-clones)
- `--update --verbose` - Show detailed progress

### Docker Template

- `--update` - Pull latest image and recreate container
- `--update --verbose` - Show detailed progress

### Rollback

Binary and Python templates automatically rollback on failure:

- Backup created in `/tmp/swizzin-update-backups/{app}/` before update
- If update fails (download, extraction, or service start), previous version restored
- Backup cleaned up after successful update or on system reboot
