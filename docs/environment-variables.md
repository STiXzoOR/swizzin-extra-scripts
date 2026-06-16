# Environment Variables

All scripts with interactive prompts can be automated via environment variables.

## Common Pattern

Scripts with subdomain support accept these variables:

| Variable               | Description                                      |
| ---------------------- | ------------------------------------------------ |
| `<APP>_DOMAIN`         | Public FQDN (bypasses domain prompt)             |
| `<APP>_LE_HOSTNAME`    | Let's Encrypt hostname (defaults to domain)      |
| `<APP>_LE_INTERACTIVE` | Set to `yes` for interactive LE (CloudFlare DNS) |
| `<APP>_OWNER`          | App owner username (defaults to master user)     |

Where `<APP>` is: `PLEX`, `EMBY`, `JELLYFIN`, `ORGANIZR`, `SEERR`, `LINGARR`, `LIBRETRANSLATE`, `PANEL`

## App-Specific Variables

### LibreTranslate

| Variable                           | Description                                    |
| ---------------------------------- | ---------------------------------------------- |
| `LIBRETRANSLATE_LANGUAGES`         | Comma-separated language codes to pre-download |
| `LIBRETRANSLATE_GPU`               | Force `cuda` or `cpu` (skips auto-detection)   |
| `LIBRETRANSLATE_CONFIGURE_LINGARR` | Set to `yes` or `no` to skip Lingarr prompt    |

### Notifiarr

| Variable     | Description                                 |
| ------------ | ------------------------------------------- |
| `DN_API_KEY` | Notifiarr.com API key (prompted if not set) |

### Subgen

| Variable       | Description                                              |
| -------------- | -------------------------------------------------------- |
| `SUBGEN_MODEL` | Whisper model (tiny/small/medium/large-v3/etc)           |

### Zurg

| Variable     | Description                                 |
| ------------ | ------------------------------------------- |
| `ZURG_TOKEN` | Real-Debrid API token (prompted if not set) |

## Example Usage

```bash
# Automated Plex subdomain setup
PLEX_DOMAIN="plex.example.com" bash plex.sh --subdomain

# Automated LibreTranslate with GPU and specific languages
LIBRETRANSLATE_GPU="cuda" \
LIBRETRANSLATE_LANGUAGES="en,es,fr,de" \
LIBRETRANSLATE_CONFIGURE_LINGARR="yes" \
bash libretranslate.sh

# Automated Notifiarr install
DN_API_KEY="your-api-key-here" bash notifiarr.sh
```
