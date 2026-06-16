# Swizzin App Info Tool

Python utility that discovers installed Swizzin apps and extracts configuration details (URLs, API keys, config file paths).

## Installation

```bash
# Install globally
sudo ./swizzin-app-info --install   # Installs to /usr/local/bin/

# Or run directly
./swizzin-app-info
```

## Usage

```bash
swizzin-app-info                    # List all installed apps
swizzin-app-info --json             # Output as JSON
swizzin-app-info --app sonarr       # Show specific app
swizzin-app-info --verbose          # Include config file paths
swizzin-app-info --uninstall        # Remove global installation
```

## How It Works

1. Discovers installed apps via lock files in `/install/`
2. Parses app config files to extract port, baseurl, and API key
3. Falls back to nginx config or systemd environment if config parsing fails

## Supported Config Formats

- XML
- JSON
- YAML
- TOML
- INI
- PHP
- dotenv
- Docker Compose

## Adding New Apps

Add an entry to the `APP_CONFIGS` dictionary. See [Maintenance Checklist](../maintenance-checklist.md#2-update-swizzin-app-info) for the required fields.
