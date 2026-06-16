# Organizr (SSO Gateway)

Extended installer for Organizr with subdomain and SSO authentication support.

## Features

- Runs `box install organizr` first if Organizr isn't installed
- Converts from subfolder (`/organizr`) to subdomain mode
- Uses Organizr as SSO authentication gateway for other apps via `auth_request`
- Stores config at `/opt/swizzin-extras/organizr-auth.conf`
- Backups at `/opt/swizzin-extras/organizr-backups/`

## Usage

```bash
bash organizr.sh                    # Interactive setup
bash organizr.sh --subdomain        # Convert to subdomain mode
bash organizr.sh --subdomain --revert  # Revert to subfolder mode
bash organizr.sh --configure        # Modify which apps are protected
bash organizr.sh --migrate          # Fix auth_request placement in redirect blocks
bash organizr.sh --remove           # Complete removal (runs box remove organizr)
```

## Auth Levels

| Level | Role       |
| ----- | ---------- |
| 0     | Admin      |
| 1     | Co-Admin   |
| 2     | Super User |
| 3     | Power User |
| 4     | User       |
| 998   | Logged In  |

## Key Files

| Path                                     | Purpose                                |
| ---------------------------------------- | -------------------------------------- |
| `/etc/nginx/sites-available/organizr`    | Subdomain vhost with auth endpoint     |
| `/etc/nginx/snippets/organizr-apps.conf` | Dynamic includes (excludes panel.conf) |
| `/opt/swizzin-extras/organizr-auth.conf` | Protected apps configuration           |

## Auth Mechanism

Uses internal rewrite to `/api/v2/auth?group=N` which is handled by the existing PHP location block.

Apps add `auth_request /organizr-auth/auth-0;` to their location blocks:

- Only on `proxy_pass` blocks
- Not on `return 301` redirects

## Note

Swizzin's automated Organizr wizard may fail to create the database. Users should complete setup manually via the web interface if needed.
