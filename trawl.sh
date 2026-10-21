#!/bin/bash
set -euo pipefail
# trawl installer
# STiXzoOR 2026
# Usage: bash trawl.sh [--update [--verbose]|--remove [--force]|--rollback|--register-panel]
#
# TRAWL — self-hosted scraping engine that clears JS challenges and CAPTCHAs
# (Cloudflare, Turnstile, Anubis, reCAPTCHA, hCaptcha). FlareSolverr-compatible
# /v1 endpoint for Prowlarr/Jackett/Bazarr, plus a native /scrape and browser
# session API (needed by MediaFusion v6's ext.to scraper — Byparr lacks it).
#
# Upstream: https://github.com/germondai/trawl
# Image:    ghcr.io/germondai/trawl (":baseline" for CPUs without AVX2)
#
# Listens on 127.0.0.1:8191 (TRAWL_PORT) so FlareSolverr clients need no
# change. When Byparr or FlareSolverr already own the port, they are stopped
# and disabled (not removed) — `--rollback` brings them back.
# mediafusion.sh uses this shared TRAWL instead of its sidecar when installed.

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# ==============================================================================
# Panel Helper - Download and cache for panel integration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
    if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
        . "${SCRIPT_DIR}/panel_helpers.sh"
        return
    fi
    if [[ -f "$PANEL_HELPER_CACHE" ]]; then
        . "$PANEL_HELPER_CACHE"
        return
    fi
    echo_info "panel_helpers.sh not found; skipping panel integration"
}

# ==============================================================================
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_systemd_unit_written=""
_services_stopped=()

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -f "${app_dir}/docker-compose.yml" ]] \
            && docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
        if [[ -n "$_systemd_unit_written" ]]; then
            systemctl disable "$_systemd_unit_written" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        fi
        local svc
        for svc in "${_services_stopped[@]}"; do
            systemctl enable -q "$svc" 2>/dev/null || true
            systemctl start "$svc" 2>/dev/null || true
            echo_info "Restarted ${svc}"
        done
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ==============================================================================
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

# ==============================================================================
# App Configuration
# ==============================================================================
app_name="trawl"
app_pretty="TRAWL"
app_lockname="${app_name}"

app_dir="/opt/${app_name}"
app_metricsdir="${app_dir}/metrics"
app_statefile="${app_dir}/.replaced"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="placeholder"

if [[ -n "${TRAWL_PORT:-}" ]]; then
    app_port="$TRAWL_PORT"
elif _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=8191
fi

# Older x86 CPUs and NAS kernels need the baseline build
if [[ -n "${TRAWL_IMAGE:-}" ]]; then
    app_image="$TRAWL_IMAGE"
elif [[ "$(uname -m)" == "x86_64" ]] && ! grep -qw avx2 /proc/cpuinfo; then
    app_image="ghcr.io/germondai/trawl:baseline"
else
    app_image="ghcr.io/germondai/trawl:latest"
fi

# Services that would otherwise own the port
replaceable=(byparr flaresolverr)

# ==============================================================================
# Docker Installation
# ==============================================================================
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_progress_start "Installing Docker"

    apt_install ca-certificates curl gnupg

    . /etc/os-release

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$log" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update >>"$log" 2>&1

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }

    systemctl enable --now docker >>"$log" 2>&1

    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_progress_done "Docker installed"
}

# ==============================================================================
# Port Takeover (Byparr / FlareSolverr)
# ==============================================================================
_take_over_port() {
    local svc found=()
    for svc in "${replaceable[@]}"; do
        if systemctl is-active -q "$svc" 2>/dev/null; then
            found+=("$svc")
        fi
    done

    if [[ ${#found[@]} -gt 0 ]]; then
        echo_warn "${found[*]} is running and serves the FlareSolverr API"
        local replace="${TRAWL_REPLACE:-}"
        if [[ -z "$replace" ]]; then
            if ask "Replace it with ${app_pretty} on port ${app_port} (it is stopped and kept for --rollback)?" Y; then
                replace=yes
            else
                replace=no
            fi
        fi
        if [[ "$replace" != "yes" ]]; then
            echo_info "Set TRAWL_PORT to run ${app_pretty} next to it instead"
            exit 1
        fi
        mkdir -p "$app_dir"
        for svc in "${found[@]}"; do
            systemctl stop "$svc"
            systemctl disable -q "$svc" 2>/dev/null || true
            _services_stopped+=("$svc")
            echo "$svc" >>"$app_statefile"
            echo_info "Stopped and disabled ${svc}"
        done
    fi

    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${app_port}\$"; then
        echo_error "Port ${app_port} is still in use — set TRAWL_PORT to another port"
        exit 1
    fi
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
_write_compose() {
    local cpu_limit="${DOCKER_CPU_LIMIT:-4}"
    local mem_limit="${DOCKER_MEM_LIMIT:-6G}"
    local pool="${TRAWL_POOL_SIZE:-3}"

    # Single process, so the clearance/session cache lives in memory (no Redis).
    # Each pooled browser holds a warm Camoufox instance (~300-400 MB).
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  ${app_name}:
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${app_port}:8191"
    shm_size: 1gb
    environment:
      SESSION_CACHE_DRIVER: memory
      BROWSER_POOL_SIZE: "${pool}"
      LOG_LEVEL: info
      MCP_ENABLED: "false"
      METRICS_DASHBOARD_ENABLED: "true"
      METRICS_DB_PATH: /data/metrics/trawl.sqlite
    volumes:
      - ${app_metricsdir}:/data/metrics
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8191/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
    security_opt:
      - no-new-privileges:true
COMPOSE
    chmod 644 "${app_dir}/docker-compose.yml"
}

_wait_for_trawl() {
    local i
    echo_progress_start "Waiting for ${app_pretty} (browsers warm up first)"
    for ((i = 0; i < 180; i += 3)); do
        if curl -sf --max-time 5 "http://127.0.0.1:${app_port}/health" >/dev/null 2>&1; then
            echo_progress_done "${app_pretty} is healthy"
            return 0
        fi
        sleep 3
    done
    echo_error "${app_pretty} did not become healthy within 3 minutes (docker logs ${app_name})"
    exit 1
}

# ==============================================================================
# Install
# ==============================================================================
_install_trawl() {
    mkdir -p "$app_dir" "$app_metricsdir"
    swizdb set "${app_name}/port" "$app_port"

    _write_compose

    echo_progress_start "Pulling ${app_pretty} image"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull ${app_image}"
        exit 1
    }
    echo_progress_done "Image pulled"

    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    _wait_for_trawl
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_trawl() {
    echo_progress_start "Installing systemd service"
    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (challenge-solving scraper, FlareSolverr-compatible)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    systemctl start "$app_servicefile" >>"$log" 2>&1 || true
    echo_progress_done "Systemd service installed and enabled"
}

_register_panel() {
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "$app_pretty" \
            "" \
            "http://127.0.0.1:${app_port}/dashboard" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    fi
}

# ==============================================================================
# Rollback (restore the replaced Byparr / FlareSolverr)
# ==============================================================================
_rollback_trawl() {
    if [[ ! -s "$app_statefile" ]]; then
        echo_error "${app_pretty} did not replace any service — nothing to roll back"
        exit 1
    fi
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable -q "$app_servicefile" 2>/dev/null || true
    local svc
    while read -r svc; do
        [[ -n "$svc" ]] || continue
        systemctl enable -q "$svc" && systemctl start "$svc" && echo_info "Started ${svc}"
    done <"$app_statefile"
    echo_success "Rolled back — ${app_pretty} is stopped (remove it with --remove)"
    exit 0
}

# ==============================================================================
# Update
# ==============================================================================
_update_trawl() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    echo_info "Updating ${app_pretty}..."
    _write_compose
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    _wait_for_trawl
    docker image prune -f >>"$log" 2>&1 || true
    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_trawl() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    docker rmi "$app_image" >>"$log" 2>&1 || true

    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        panel_unregister_app "$app_name"
    fi

    if [[ -s "$app_statefile" ]]; then
        echo_warn "Replaced services are still disabled: $(tr '\n' ' ' <"$app_statefile")"
        echo_info "Re-enable them with: systemctl enable --now <service>"
    fi
    if [[ -f /install/.mediafusion.lock ]]; then
        echo_warn "MediaFusion points at this TRAWL; re-run its installer to restore the bundled sidecar"
    fi

    rm -rf "$app_dir"
    swizdb clear "${app_name}/port" 2>/dev/null || true
    rm -f "/install/.${app_lockname}.lock"
    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Main
# ==============================================================================
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

case "${1:-}" in
    "--remove")
        _remove_trawl "${2:-}"
        ;;
    "--update")
        _update_trawl
        ;;
    "--rollback")
        _rollback_trawl
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        _register_panel
        systemctl restart panel 2>/dev/null || true
        echo_success "Panel registration updated for ${app_pretty}"
        exit 0
        ;;
    "" | "--verbose") ;;
    *)
        echo "Usage: $0 [--update [--verbose]|--remove [--force]|--rollback|--register-panel]"
        exit 1
        ;;
esac

if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    _cleanup_needed=true
    _install_docker
    _take_over_port
    _install_trawl
    _systemd_trawl
fi

_register_panel
touch "/install/.${app_lockname}.lock"
_cleanup_needed=false

echo_success "${app_pretty} installed"
echo_info "FlareSolverr-compatible endpoint: http://127.0.0.1:${app_port}/v1"
echo_info "Dashboard: http://127.0.0.1:${app_port}/dashboard (ssh -L ${app_port}:127.0.0.1:${app_port})"
[[ -s "$app_statefile" ]] && echo_info "Roll back to $(tr '\n' ' ' <"$app_statefile")with: bash $0 --rollback"
exit 0
