# Plex Tunnel

Plex in a Docker container with VPN tunnel support to bypass Hetzner IP bans.

## Problem

Plex has banned Hetzner IP ranges, preventing Plex.tv authentication and remote access from Hetzner dedicated servers.

## Solution

`plex-tunnel.sh` installs Plex in a Docker container with traffic routed through a VPN tunnel, presenting a clean (non-Hetzner) IP address to Plex servers.

## Modes

### Gluetun Mode (Recommended)

Routes Plex traffic through a commercial VPN provider using [Gluetun](https://github.com/qdm12/gluetun).

**Supported providers:** NordVPN, Surfshark, ProtonVPN, Mullvad, PIA, ExpressVPN, IVPN, Windscribe, and many more.

### WireGuard Relay Mode

Routes Plex traffic through a self-hosted WireGuard VPN on an external VPS with a clean IP.

## File Layout

| Path                                     | Purpose                    |
| ---------------------------------------- | -------------------------- |
| `/opt/plex-tunnel/docker-compose.yml`    | Docker Compose file        |
| `/opt/plex-tunnel/config/`               | Plex configuration         |
| `/opt/plex-tunnel/gluetun/`              | Gluetun data (Gluetun mode)|
| `/opt/plex-tunnel/wireguard/wg0.conf`    | WireGuard config (WG mode) |
| `/etc/nginx/sites-available/plex-tunnel` | Subdomain vhost (optional) |
| `/etc/systemd/system/plex-tunnel.service`| Systemd wrapper            |
| `/install/.plextunnel.lock`              | Swizzin lock file          |

---

## Quick Start

### Gluetun Mode with Mullvad

```bash
VPN_PROVIDER="mullvad" \
VPN_TYPE="wireguard" \
WIREGUARD_PRIVATE_KEY="your-private-key" \
WIREGUARD_ADDRESSES="10.x.x.x/32" \
PLEX_CLAIM="claim-xxxxx" \
bash plex-tunnel.sh --gluetun
```

### Gluetun Mode with NordVPN

```bash
VPN_PROVIDER="nordvpn" \
VPN_TYPE="wireguard" \
WIREGUARD_PRIVATE_KEY="your-private-key" \
SERVER_COUNTRIES="Netherlands" \
PLEX_CLAIM="claim-xxxxx" \
bash plex-tunnel.sh --gluetun
```

### WireGuard Relay Mode

1. First, set up WireGuard server on your VPS:
   ```bash
   # On your VPS (with clean IP)
   bash plex-tunnel-vps.sh
   ```

2. Copy the outputted configuration, then on Hetzner:
   ```bash
   WG_RELAY_ENDPOINT="vps.example.com:51820" \
   WG_RELAY_PUBKEY="server-public-key" \
   WG_RELAY_PRIVKEY="client-private-key" \
   WG_RELAY_ADDRESS="10.13.13.2/24" \
   WG_RELAY_PRESHARED="preshared-key" \
   PLEX_CLAIM="claim-xxxxx" \
   bash plex-tunnel.sh --wireguard
   ```

---

## Provider-Specific Configuration

### NordVPN

Get your WireGuard private key from the NordVPN dashboard (Manual setup > WireGuard).

```bash
VPN_PROVIDER="nordvpn"
VPN_TYPE="wireguard"
WIREGUARD_PRIVATE_KEY="your-nordvpn-private-key"
SERVER_COUNTRIES="Netherlands"  # Optional
```

Or with OpenVPN:

```bash
VPN_PROVIDER="nordvpn"
VPN_TYPE="openvpn"
OPENVPN_USER="your-nordvpn-email"
OPENVPN_PASSWORD="your-nordvpn-password"
```

### Surfshark

Get credentials from Surfshark dashboard (Manual setup).

```bash
VPN_PROVIDER="surfshark"
VPN_TYPE="wireguard"
WIREGUARD_PRIVATE_KEY="your-surfshark-private-key"
WIREGUARD_ADDRESSES="10.x.x.x/32"  # From config
```

### ProtonVPN

Get OpenVPN credentials from ProtonVPN account page.

```bash
VPN_PROVIDER="protonvpn"
VPN_TYPE="openvpn"
OPENVPN_USER="your-protonvpn-openvpn-username"
OPENVPN_PASSWORD="your-protonvpn-openvpn-password"
```

### Mullvad

Get WireGuard key from Mullvad account page.

```bash
VPN_PROVIDER="mullvad"
VPN_TYPE="wireguard"
WIREGUARD_PRIVATE_KEY="your-mullvad-private-key"
WIREGUARD_ADDRESSES="10.x.x.x/32"  # From Mullvad config
```

### PIA (Private Internet Access)

```bash
VPN_PROVIDER="pia"
VPN_TYPE="openvpn"  # Or wireguard
OPENVPN_USER="your-pia-username"
OPENVPN_PASSWORD="your-pia-password"
```

---

## Commands

```bash
# Install with Gluetun VPN
bash plex-tunnel.sh --gluetun

# Install with WireGuard relay
bash plex-tunnel.sh --wireguard

# Add subdomain with SSL
PLEX_TUNNEL_DOMAIN="plex.example.com" bash plex-tunnel.sh --subdomain

# Remove subdomain
bash plex-tunnel.sh --subdomain --revert

# Check status
bash plex-tunnel.sh --status

# Update containers
bash plex-tunnel.sh --update

# Remove
bash plex-tunnel.sh --remove
```

---

## Environment Variables

### Gluetun Mode

| Variable | Description | Required |
| -------- | ----------- | -------- |
| `VPN_PROVIDER` | VPN provider name | Yes |
| `VPN_TYPE` | `wireguard` or `openvpn` | No (default: wireguard) |
| `WIREGUARD_PRIVATE_KEY` | WireGuard private key | Yes (for WireGuard) |
| `WIREGUARD_ADDRESSES` | WireGuard address | Some providers |
| `OPENVPN_USER` | OpenVPN username | Yes (for OpenVPN) |
| `OPENVPN_PASSWORD` | OpenVPN password | Yes (for OpenVPN) |
| `SERVER_COUNTRIES` | Server country filter | No |

### WireGuard Relay Mode

| Variable | Description | Required |
| -------- | ----------- | -------- |
| `WG_RELAY_ENDPOINT` | VPS endpoint (host:port) | Yes |
| `WG_RELAY_PUBKEY` | Server public key | Yes |
| `WG_RELAY_PRIVKEY` | Client private key | Yes |
| `WG_RELAY_ADDRESS` | Client tunnel address | Yes |
| `WG_RELAY_PRESHARED` | Preshared key | No |

### Common

| Variable | Description | Required |
| -------- | ----------- | -------- |
| `PLEX_CLAIM` | Plex claim token | No (but needed for linking) |
| `PLEX_TUNNEL_DOMAIN` | Domain for subdomain mode | For subdomain |
| `TZ` | Timezone | No (default: from system) |

---

## Migration from Native Plex

If you have an existing native Plex installation, the script will:

1. Detect it at `/var/lib/plexmediaserver`
2. Offer to migrate configuration and metadata
3. Create a backup before migrating
4. Disable (not remove) the native Plex service
5. Copy config to the container volume

After verifying the migration works, you can remove native Plex:

```bash
box remove plex
```

---

## Media Path Auto-Detection

The script automatically discovers media paths from all installed *arr applications:

- Base instances: Sonarr, Radarr, Lidarr, Readarr
- Multi-instances: sonarr-4k, radarr-anime, etc.

Media paths are mounted with identical paths inside the container, so Plex sees the same filesystem structure as your *arr apps.

---

## Troubleshooting

### Check tunnel connectivity

```bash
bash plex-tunnel.sh --status
```

This shows:
- Container status
- External IP (should be VPN IP, not Hetzner IP)
- Plex server responsiveness

### Check VPN IP manually

```bash
# For Gluetun mode
docker exec plex-tunnel-gluetun wget -qO- ifconfig.me

# For WireGuard mode
docker exec plex-tunnel-wireguard wget -qO- ifconfig.me
```

### View container logs

```bash
# All containers
docker compose -f /opt/plex-tunnel/docker-compose.yml logs

# Specific container
docker logs plex-tunnel-gluetun
docker logs plex-tunnel
```

### Plex not accessible

1. Check if containers are running:
   ```bash
   docker compose -f /opt/plex-tunnel/docker-compose.yml ps
   ```

2. Check if Gluetun/WireGuard is healthy:
   ```bash
   docker logs plex-tunnel-gluetun | tail -50
   ```

3. Verify port is accessible:
   ```bash
   curl -s http://127.0.0.1:32400/identity
   ```

### VPN not connecting

- Verify credentials are correct
- Try a different server country
- Check Gluetun logs for specific error messages
- For WireGuard relay: verify VPS firewall allows UDP on WireGuard port

---

## VPS Setup (WireGuard Relay)

For WireGuard relay mode, you need a VPS with a clean (non-Hetzner) IP. Run `plex-tunnel-vps.sh` on the VPS:

```bash
# Basic setup
bash plex-tunnel-vps.sh

# Custom ports
WG_PORT=51821 PLEX_PORT=32401 bash plex-tunnel-vps.sh

# Remove
bash plex-tunnel-vps.sh --remove
```

The script will:
1. Install Docker if needed
2. Generate WireGuard keys
3. Set up port forwarding for Plex
4. Output configuration for your Hetzner server

### VPS Firewall

Ensure these ports are open on your VPS:

```bash
# UFW example
ufw allow 51820/udp   # WireGuard
ufw allow 32400/tcp   # Plex
ufw allow 32400/udp   # Plex
```

### Recommended VPS Providers

- DigitalOcean
- Vultr
- Linode
- OVH (non-Hetzner regions)
- Oracle Cloud (free tier)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     HETZNER SERVER                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Docker Compose Stack                        │   │
│  │  ┌───────────────┐      ┌───────────────┐              │   │
│  │  │   Gluetun     │      │     Plex      │              │   │
│  │  │  (VPN Client) │◄────►│  network_mode:│              │   │
│  │  │  :32400 pub   │      │  service:gluetun             │   │
│  │  └───────────────┘      └───────────────┘              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                    ┌─────────▼─────────┐                       │
│                    │  Nginx Reverse    │                       │
│                    │  Proxy (optional) │                       │
│                    └───────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
                               │
                    VPN Tunnel / WireGuard
                               │
                               ▼
                    ┌───────────────────┐
                    │  VPN Exit / VPS   │
                    │  (Clean IP)       │
                    └───────────────────┘
```
