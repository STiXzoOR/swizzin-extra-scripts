#!/bin/bash
# plex-tunnel-vps - WireGuard server setup for Plex tunnel relay
# STiXzoOR 2025
#
# Run this script on your VPS (with a clean IP) to set up a WireGuard server
# that will relay Plex traffic from your Hetzner server.
#
# Usage: bash plex-tunnel-vps.sh [--remove]

set -euo pipefail

# ==============================================================================
# Colors (simple implementation for standalone script)
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
echo_success() { echo -e "${GREEN}[OK]${NC} $*"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_nginx_symlink_created=""
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_nginx_symlink_created" ]] && rm -f "$_nginx_symlink_created"
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
        _reload_nginx 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Configuration
# ==============================================================================
WG_PORT="${WG_PORT:-51820}"
PLEX_PORT="${PLEX_PORT:-32400}"
WG_SERVER_ADDRESS="${WG_SERVER_ADDRESS:-10.13.13.1/24}"
WG_CLIENT_ADDRESS="${WG_CLIENT_ADDRESS:-10.13.13.2/24}"
WG_DIR="/opt/plex-tunnel-wg"

# ==============================================================================
# Pre-flight Checks
# ==============================================================================
_preflight() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run as root"
        exit 1
    fi

    # Check if running on likely-banned IP ranges (optional warning)
    local ip
    ip=$(curl -sf --max-time 10 ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$ip" ]]; then
        echo_info "VPS external IP: $ip"
        # Basic Hetzner range detection (not exhaustive)
        if [[ "$ip" =~ ^(5\.9\.|23\.88\.|49\.12\.|65\.21\.|78\.46\.|88\.99\.|91\.107\.|94\.130\.|95\.216\.|116\.202\.|116\.203\.|128\.140\.|135\.181\.|136\.243\.|138\.201\.|142\.132\.|144\.76\.|148\.251\.|157\.90\.|159\.69\.|162\.55\.|167\.235\.|168\.119\.|176\.9\.|178\.63\.|185\.107\.|188\.40\.|195\.201\.|213\.133\.|213\.239\.) ]]; then
            echo_warn "This IP appears to be in Hetzner range - it may be blocked by Plex"
            echo_warn "For best results, use a VPS from a different provider"
        fi
    fi
}

# ==============================================================================
# Docker Installation
# ==============================================================================
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_info "Installing Docker..."

    # Detect distribution
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
    else
        echo_error "Cannot detect OS distribution"
        exit 1
    fi

    # Install prerequisites
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # Add Docker GPG key and repository
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable --now docker

    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_success "Docker installed"
}

# ==============================================================================
# WireGuard Key Generation
# ==============================================================================
_generate_keys() {
    echo_info "Generating WireGuard keys..."

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    # Generate server keys
    if [[ ! -f "${WG_DIR}/server_privatekey" ]]; then
        wg genkey | tee "${WG_DIR}/server_privatekey" | wg pubkey >"${WG_DIR}/server_publickey"
        chmod 600 "${WG_DIR}/server_privatekey"
    fi

    # Generate client keys
    if [[ ! -f "${WG_DIR}/client_privatekey" ]]; then
        wg genkey | tee "${WG_DIR}/client_privatekey" | wg pubkey >"${WG_DIR}/client_publickey"
        chmod 600 "${WG_DIR}/client_privatekey"
    fi

    # Generate preshared key
    if [[ ! -f "${WG_DIR}/presharedkey" ]]; then
        wg genpsk >"${WG_DIR}/presharedkey"
        chmod 600 "${WG_DIR}/presharedkey"
    fi

    SERVER_PRIVKEY=$(cat "${WG_DIR}/server_privatekey")
    SERVER_PUBKEY=$(cat "${WG_DIR}/server_publickey")
    CLIENT_PRIVKEY=$(cat "${WG_DIR}/client_privatekey")
    CLIENT_PUBKEY=$(cat "${WG_DIR}/client_publickey")
    PRESHARED_KEY=$(cat "${WG_DIR}/presharedkey")

    echo_success "WireGuard keys generated"
}

# ==============================================================================
# WireGuard Server Configuration
# ==============================================================================
_generate_server_config() {
    echo_info "Generating WireGuard server configuration..."

    # Server address without CIDR
    local server_ip="${WG_SERVER_ADDRESS%/*}"

    cat >"${WG_DIR}/wg0.conf" <<EOF
[Interface]
Address = ${WG_SERVER_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVKEY}

# Enable IP forwarding and NAT
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
# Port forward for Plex (32400) from VPS public IP to Hetzner client
PostUp = iptables -t nat -A PREROUTING -p tcp --dport ${PLEX_PORT} -j DNAT --to-destination ${WG_CLIENT_ADDRESS%/*}:${PLEX_PORT}
PostUp = iptables -t nat -A PREROUTING -p udp --dport ${PLEX_PORT} -j DNAT --to-destination ${WG_CLIENT_ADDRESS%/*}:${PLEX_PORT}

PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D PREROUTING -p tcp --dport ${PLEX_PORT} -j DNAT --to-destination ${WG_CLIENT_ADDRESS%/*}:${PLEX_PORT}
PostDown = iptables -t nat -D PREROUTING -p udp --dport ${PLEX_PORT} -j DNAT --to-destination ${WG_CLIENT_ADDRESS%/*}:${PLEX_PORT}

[Peer]
# Hetzner server (Plex client)
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${WG_CLIENT_ADDRESS}
EOF

    chmod 600 "${WG_DIR}/wg0.conf"

    echo_success "Server configuration generated"
}

# ==============================================================================
# Docker Compose for WireGuard Server
# ==============================================================================
_generate_compose() {
    echo_info "Generating Docker Compose configuration..."

    cat >"${WG_DIR}/docker-compose.yml" <<EOF
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: plex-tunnel-wg-server
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=0
      - PGID=0
      - TZ=UTC
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${PLEX_PORT}:${PLEX_PORT}/tcp"
      - "${PLEX_PORT}:${PLEX_PORT}/udp"
    volumes:
      - ${WG_DIR}:/config
      - /lib/modules:/lib/modules:ro
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    restart: unless-stopped
EOF

    echo_success "Docker Compose configuration generated"
}

# ==============================================================================
# Systemd Service
# ==============================================================================
_install_systemd() {
    echo_info "Installing systemd service..."

    cat >/etc/systemd/system/plex-tunnel-wg.service <<EOF
[Unit]
Description=Plex Tunnel WireGuard Server
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${WG_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable plex-tunnel-wg.service

    echo_success "Systemd service installed"
}

# ==============================================================================
# Start Server
# ==============================================================================
_start_server() {
    echo_info "Starting WireGuard server..."

    docker compose -f "${WG_DIR}/docker-compose.yml" pull
    docker compose -f "${WG_DIR}/docker-compose.yml" up -d

    # Wait for container to start
    sleep 5

    if docker ps | grep -q plex-tunnel-wg-server; then
        echo_success "WireGuard server started"
    else
        echo_error "Failed to start WireGuard server"
        docker logs plex-tunnel-wg-server 2>&1 | tail -20
        exit 1
    fi
}

# ==============================================================================
# Output Client Configuration
# ==============================================================================
_output_client_config() {
    local vps_ip
    vps_ip=$(curl -sf --max-time 10 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    echo "=============================================================================="
    echo "  WireGuard Server Setup Complete!"
    echo "=============================================================================="
    echo ""
    echo "VPS Public IP: $vps_ip"
    echo "WireGuard Port: $WG_PORT"
    echo "Plex Port: $PLEX_PORT"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "  Client Configuration for Hetzner Server"
    echo "------------------------------------------------------------------------------"
    echo ""
    echo "Use these values when running plex-tunnel.sh --wireguard on your Hetzner server:"
    echo ""
    echo "  WG_RELAY_ENDPOINT=\"${vps_ip}:${WG_PORT}\""
    echo "  WG_RELAY_PUBKEY=\"${SERVER_PUBKEY}\""
    echo "  WG_RELAY_PRIVKEY=\"${CLIENT_PRIVKEY}\""
    echo "  WG_RELAY_ADDRESS=\"${WG_CLIENT_ADDRESS}\""
    echo "  WG_RELAY_PRESHARED=\"${PRESHARED_KEY}\""
    echo ""
    echo "Or run the following command on your Hetzner server:"
    echo ""
    echo "  WG_RELAY_ENDPOINT=\"${vps_ip}:${WG_PORT}\" \\"
    echo "  WG_RELAY_PUBKEY=\"${SERVER_PUBKEY}\" \\"
    echo "  WG_RELAY_PRIVKEY=\"${CLIENT_PRIVKEY}\" \\"
    echo "  WG_RELAY_ADDRESS=\"${WG_CLIENT_ADDRESS}\" \\"
    echo "  WG_RELAY_PRESHARED=\"${PRESHARED_KEY}\" \\"
    echo "  bash plex-tunnel.sh --wireguard"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "  Firewall Configuration"
    echo "------------------------------------------------------------------------------"
    echo ""
    echo "Make sure the following ports are open on your VPS firewall:"
    echo "  - UDP ${WG_PORT} (WireGuard)"
    echo "  - TCP ${PLEX_PORT} (Plex)"
    echo "  - UDP ${PLEX_PORT} (Plex)"
    echo ""
    echo "Example (UFW):"
    echo "  ufw allow ${WG_PORT}/udp"
    echo "  ufw allow ${PLEX_PORT}/tcp"
    echo "  ufw allow ${PLEX_PORT}/udp"
    echo ""

    # Save client config to file for easy reference
    cat >"${WG_DIR}/client-config.txt" <<EOF
# Plex Tunnel WireGuard Client Configuration
# Generated: $(date)

# For use with plex-tunnel.sh --wireguard on Hetzner server:

WG_RELAY_ENDPOINT="${vps_ip}:${WG_PORT}"
WG_RELAY_PUBKEY="${SERVER_PUBKEY}"
WG_RELAY_PRIVKEY="${CLIENT_PRIVKEY}"
WG_RELAY_ADDRESS="${WG_CLIENT_ADDRESS}"
WG_RELAY_PRESHARED="${PRESHARED_KEY}"
EOF

    chmod 600 "${WG_DIR}/client-config.txt"
    echo "Client configuration saved to: ${WG_DIR}/client-config.txt"
    echo ""
}

# ==============================================================================
# Remove
# ==============================================================================
_remove() {
    echo_info "Removing Plex Tunnel WireGuard server..."

    # Stop and remove container
    if [[ -f "${WG_DIR}/docker-compose.yml" ]]; then
        docker compose -f "${WG_DIR}/docker-compose.yml" down 2>/dev/null || true
    fi

    # Remove systemd service
    systemctl stop plex-tunnel-wg.service 2>/dev/null || true
    systemctl disable plex-tunnel-wg.service 2>/dev/null || true
    rm -f /etc/systemd/system/plex-tunnel-wg.service
    systemctl daemon-reload

    # Ask about removing config
    echo ""
    read -p "Remove WireGuard keys and configuration? [y/N] " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$WG_DIR"
        echo_success "Configuration removed"
    else
        echo_info "Configuration kept at: $WG_DIR"
    fi

    # Remove Docker image
    docker rmi lscr.io/linuxserver/wireguard 2>/dev/null || true

    echo_success "Plex Tunnel WireGuard server removed"
    exit 0
}

# ==============================================================================
# Usage
# ==============================================================================
_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Set up a WireGuard server on your VPS to relay Plex traffic from a Hetzner server.

OPTIONS:
  (no args)    Install WireGuard server
  --remove     Remove WireGuard server

ENVIRONMENT VARIABLES:
  WG_PORT            WireGuard listen port (default: 51820)
  PLEX_PORT          Plex port to forward (default: 32400)
  WG_SERVER_ADDRESS  Server tunnel address (default: 10.13.13.1/24)
  WG_CLIENT_ADDRESS  Client tunnel address (default: 10.13.13.2/24)

EXAMPLE:
  # Install with defaults
  bash plex-tunnel-vps.sh

  # Install with custom port
  WG_PORT=51821 bash plex-tunnel-vps.sh

After installation, use the outputted configuration values with plex-tunnel.sh
on your Hetzner server.

EOF
    exit 0
}

# ==============================================================================
# Main
# ==============================================================================
case "${1:-}" in
    "--remove")
        _remove
        ;;
    "--help" | "-h")
        _usage
        ;;
    "")
        _preflight
        _install_docker

        # Install wg tools for key generation (may already be available in container)
        if ! command -v wg >/dev/null 2>&1; then
            echo_info "Installing WireGuard tools..."
            apt-get update
            apt-get install -y wireguard-tools
        fi

        _generate_keys
        _generate_server_config
        _generate_compose
        _install_systemd
        _start_server
        _output_client_config
        ;;
    *)
        _usage
        ;;
esac
