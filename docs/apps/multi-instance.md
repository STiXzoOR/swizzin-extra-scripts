# Multi-Instance Scripts

Scripts for managing multiple named instances of arr apps.

## Supported Apps

| Script     | Base App                | Multi-Instance Pattern         |
| ---------- | ----------------------- | ------------------------------ |
| sonarr.sh  | Swizzin's sonarr        | `~/.config/sonarr-<name>/`     |
| radarr.sh  | Swizzin's radarr        | `~/.config/radarr-<name>/`     |
| bazarr.sh  | Swizzin's bazarr        | `~/.config/bazarr-<name>/`     |

## Usage (Sonarr/Radarr)

```bash
sonarr.sh                      # Install base if needed, then add instances interactively
sonarr.sh --add [name]         # Add a named instance (e.g., 4k, anime, kids)
sonarr.sh --remove [name]      # Remove instance(s) - interactive if no name
sonarr.sh --remove name --force # Remove without prompts, purge config
sonarr.sh --list               # List all instances with ports
```

## Usage (Bazarr)

```bash
bazarr.sh                      # Install base if needed, then add instances interactively
bazarr.sh --add [name]         # Add a named instance (e.g., 4k, anime, kids)
bazarr.sh --remove [name]      # Remove instance(s) - interactive if no name
bazarr.sh --list               # List all instances with ports
bazarr.sh --migrate            # Run all migrations (location + config format)
bazarr.sh --register-panel     # Re-register all instances with swizzin panel
```

## Naming Convention

| Component  | Pattern                               | Example                          |
| ---------- | ------------------------------------- | -------------------------------- |
| Service    | `sonarr-<name>.service`               | `sonarr-4k.service`              |
| Config dir | `/home/<user>/.config/sonarr-<name>/` | `/home/user/.config/sonarr-4k/`  |
| Nginx      | `/etc/nginx/apps/sonarr-<name>.conf`  | `/etc/nginx/apps/sonarr-4k.conf` |
| URL path   | `/sonarr-<name>/`                     | `/sonarr-4k/`                    |
| Lock file  | `/install/.sonarr_<name>.lock`        | `/install/.sonarr_4k.lock`       |

## Instance Name Validation

- Alphanumeric only (a-z, 0-9), converted to lowercase
- Checked against existing lock files for uniqueness
- Reserved words blocked: "base"

## Port Allocation

Dynamic via `port 10000 12000` (not the base port).

## Bazarr-Specific Notes

### Base Instance Data Location

The base bazarr instance stores data in `~/.config/bazarr/` (not `/opt/bazarr/data/`). This protects data from bazarr's auto-update which wipes `/opt/bazarr/` when updating.

Run `bazarr.sh --migrate` to:
1. Move base bazarr data from `/opt/bazarr/data/` to `~/.config/bazarr/`
2. Convert legacy INI configs to YAML format

### Config Format

Bazarr uses YAML config files. The `--migrate` command converts legacy INI format to YAML.

## App Differences (Sonarr/Radarr)

| Variable        | Sonarr             | Radarr             |
| --------------- | ------------------ | ------------------ |
| `app_binary`    | /opt/Sonarr/Sonarr | /opt/Radarr/Radarr |
| `app_base_port` | 8989               | 7878               |
| `app_branch`    | main               | master             |

## Base App Protection

The base instance cannot be removed via these scripts. Remove all additional instances before running `box remove <app>`.
