#!/bin/bash
set -euo pipefail
# bazarr-plus installer
# STiXzoOR 2026
# Usage: bash bazarr-plus.sh [--update [--verbose]|--remove [--force]|--rollback|--register-panel]
#
# Bazarr+ — hard fork of Bazarr (https://github.com/LavX/bazarr): multiple
# Sonarr/Radarr instances in one install, Emby/Silo/Jellyfin/Plex refresh after
# a subtitle lands, provider plugins, mass sync, AI translation, no telemetry.
#
# Image:    ghcr.io/lavx/bazarr (tags have no "v" prefix, e.g. 2.7.2)
# Docs:     https://lavx.github.io/bazarr/
#
# Migration (default when swizzin's Bazarr is installed):
#   - Stops bazarr and every bazarr-<name> instance, and backs up each config
#     directory to /opt/swizzin-extras/bazarrplus-backups/<timestamp>/
#   - Bazarr+ starts from a COPY of the main bazarr config + database (the fork
#     adopts upstream's schema on first boot; that copy cannot go back)
#   - Each bazarr-<name> instance's Sonarr/Radarr is added as an extra
#     instance; its own database (history, blacklist) is not merged
#   - The old services are disabled, not removed: `--rollback` restarts them
#     from their untouched config directories
# Set BAZARRPLUS_MIGRATE=no to install fresh next to an existing Bazarr.
#
# Provider overlays: overlays/bazarr-plus/providers/*.py (Greek providers
# ported onto the fork) are bind-mounted read-only over the image's copies.

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

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
_nginx_config_written=""
_systemd_unit_written=""
_services_stopped=()

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        if [[ -n "$_systemd_unit_written" ]]; then
            systemctl stop "$_systemd_unit_written" 2>/dev/null || true
            systemctl disable "$_systemd_unit_written" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        fi
        [[ -f "${app_dir}/docker-compose.yml" ]] \
            && docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
        # Bring the old Bazarr instances back exactly as they were
        local svc
        for svc in "${_services_stopped[@]}"; do
            systemctl enable -q "$svc" 2>/dev/null || true
            systemctl start "$svc" 2>/dev/null || true
            echo_info "Restarted ${svc}"
        done
        _reload_nginx 2>/dev/null || true
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
app_name="bazarrplus"
app_pretty="Bazarr+"
app_lockname="${app_name}"
app_baseurl="${app_name}"

app_image="${BAZARRPLUS_IMAGE:-ghcr.io/lavx/bazarr:latest}"

app_dir="/opt/${app_name}"
app_configdir="${app_dir}/config"
app_overlaydir="${app_dir}/overlays"
app_statefile="${app_dir}/.migrated_from"
app_servicefile="${app_name}.service"
backup_root="/opt/swizzin-extras/${app_name}-backups"

app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/bazarr.png"

# Provider path inside the image
image_providers="/app/bazarr/custom_libs/subliminal_patch/providers"
overlay_src="${SCRIPT_DIR}/overlays/bazarr-plus/providers"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"

if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

# Host paths Bazarr+ needs (subtitles are written next to the media), as
# colon-separated list. Defaults to every root that exists of /mnt and /home.
_media_paths() {
    if [[ -n "${BAZARRPLUS_MEDIA_PATHS:-}" ]]; then
        tr ':' '\n' <<<"$BAZARRPLUS_MEDIA_PATHS"
        return
    fi
    local p
    for p in /mnt /home; do
        [[ -d "$p" ]] && echo "$p"
    done
}

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
# Migration Source Detection
# ==============================================================================
# Prints "service|config_dir" lines: swizzin's bazarr first, then every
# bazarr-<name> unit whose ExecStart passes --config <dir>.
_detect_sources() {
    local home cfg unit dir
    home=$(getent passwd "$user" | cut -d: -f6)
    cfg="${home}/.config/bazarr"
    if [[ -f /install/.bazarr.lock && -f "${cfg}/config/config.yaml" ]]; then
        echo "bazarr.service|${cfg}"
    fi
    for unit in $(systemctl list-unit-files --no-legend 'bazarr-*.service' 2>/dev/null | awk '{print $1}'); do
        dir=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -oP '(?<=--config )[^ ;]+' | head -1)
        if [[ -n "$dir" && -f "${dir}/config/config.yaml" ]]; then
            echo "${unit}|${dir}"
        fi
    done
}

_yaml_get() {
    python3 -c "import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for k in sys.argv[2].split('.'):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if not isinstance(d, dict) else '')" "$1" "$2"
}

# Back up every source config directory (services stopped, so the SQLite files
# are consistent). Logs are skipped; everything else is kept. Sets backup_dest.
backup_dest=""
_backup_sources() {
    local stamp dest line dir
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="${backup_root}/${stamp}"
    mkdir -p "$dest"
    chmod 700 "$backup_root" "$dest"
    for line in "$@"; do
        dir="${line#*|}"
        echo_progress_start "Backing up ${dir}"
        tar -czf "${dest}/$(basename "$dir").tar.gz" --exclude='./log' -C "$dir" . 2>>"$log" || {
            echo_error "Backup of ${dir} failed — aborting before anything changes"
            exit 1
        }
        echo_progress_done "Backed up to ${dest}/$(basename "$dir").tar.gz"
        printf '%s\n' "$line" >>"${dest}/sources"
    done
    chmod 600 "${dest}"/*
    backup_dest="$dest"
}

# ==============================================================================
# Config
# ==============================================================================
# Point Bazarr+ at its own listener: host networking, so bind loopback only.
_write_listener_config() {
    local cfg="${app_configdir}/config/config.yaml"
    mkdir -p "${app_configdir}/config"
    python3 - "$cfg" "$app_port" "/${app_baseurl}" <<'PY'
import os, sys, yaml
path, port, base = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = yaml.safe_load(open(path)) if os.path.exists(path) else {}
d = d or {}
g = d.setdefault('general', {})
g['ip'], g['port'], g['base_url'] = '127.0.0.1', port, base
yaml.safe_dump(d, open(path, 'w'), default_flow_style=False, sort_keys=False)
PY
}

_copy_overlays() {
    rm -rf "$app_overlaydir"
    mkdir -p "$app_overlaydir"
    if compgen -G "${overlay_src}/*.py" >/dev/null; then
        cp "${overlay_src}"/*.py "$app_overlaydir"/
        _verbose "Provider overlays: $(cd "$app_overlaydir" && echo *.py)"
    fi
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
_write_compose() {
    local uid gid tz p f
    uid=$(id -u "$user")
    gid=$(id -g "$user")
    tz=$(cat /etc/timezone 2>/dev/null || echo UTC)

    local cpu_limit="${DOCKER_CPU_LIMIT:-4}"
    local mem_limit="${DOCKER_MEM_LIMIT:-4G}"

    # Host networking: Sonarr/Radarr, media servers and Byparr are reached on
    # 127.0.0.1 exactly as the native Bazarr did. Hardening follows upstream's
    # compose (read-only root, all caps dropped but the three entrypoint needs).
    {
        cat <<COMPOSE
services:
  ${app_name}:
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - TZ=${tz}
COMPOSE
        if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ':8191$'; then
            echo "      - FLARESOLVERR_URL=http://127.0.0.1:8191"
        fi
        echo "    volumes:"
        echo "      - ${app_configdir}:/config"
        while read -r p; do
            [[ -n "$p" ]] && echo "      - ${p}:${p}:rslave"
        done < <(_media_paths)
        for f in "$app_overlaydir"/*.py; do
            [[ -f "$f" ]] && echo "      - ${f}:${image_providers}/$(basename "$f"):ro"
        done
        cat <<COMPOSE
    read_only: true
    tmpfs:
      - /tmp:size=512m
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
COMPOSE
    } >"${app_dir}/docker-compose.yml"
    chmod 644 "${app_dir}/docker-compose.yml"
}

# ==============================================================================
# API Helpers
# ==============================================================================
_api="http://127.0.0.1:${app_port}/${app_baseurl}/api"

# The fork encrypts the stored key ("enc:..."), so callers pass the plaintext
# key read from the migrated upstream config.
_wait_for_api() {
    local key="$1" i
    echo_progress_start "Waiting for ${app_pretty} (first boot migrates the database)"
    for ((i = 0; i < 900; i += 5)); do
        if curl -sf --max-time 5 -H "X-API-KEY: ${key}" "${_api}/system/status" >/dev/null 2>&1; then
            echo_progress_done "${app_pretty} is responding"
            return 0
        fi
        sleep 5
    done
    echo_error "${app_pretty} did not come up within 15 minutes (docker logs ${app_name})"
    exit 1
}

# Register one source instance's Sonarr/Radarr as extra instances
_add_arr_instances() {
    local key="$1" cfg="$2" label="$3" kind body code
    for kind in sonarr radarr; do
        [[ "$(_yaml_get "$cfg" "general.use_${kind}")" == "True" ]] || continue
        body=$(python3 - "$cfg" "$kind" "$label" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))[sys.argv[2]]
print(json.dumps({'kind': sys.argv[2], 'name': '%s %s' % (sys.argv[2].capitalize(), sys.argv[3]),
                  'api_key': d['apikey'], 'ip': d['ip'], 'port': int(d['port']),
                  'base_url': d.get('base_url') or '', 'ssl': bool(d.get('ssl')),
                  'enabled': True, 'is_default': False}))
PY
)
        code=$(printf '%s' "$body" | curl -s -o /dev/null -w '%{http_code}' -H "X-API-KEY: ${key}" \
            -H "Content-Type: application/json" -d @- "${_api}/system/arr-instances" 2>>"$log") || true
        if [[ "$code" == 2* ]]; then
            echo_info "Added ${kind^} ${label} as an extra instance"
        else
            echo_warn "Could not add ${kind^} ${label} (HTTP ${code}) — add it under Settings > Connections"
        fi
    done
}

# ==============================================================================
# Install / Migrate
# ==============================================================================
_start_stack() {
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
}

_install_bazarrplus() {
    local sources=() line migrate="${BAZARRPLUS_MIGRATE:-}"
    mapfile -t sources < <(_detect_sources)

    if [[ ${#sources[@]} -gt 0 && -z "$migrate" ]]; then
        echo_info "Found existing Bazarr: $(printf '%s ' "${sources[@]%%|*}")"
        if ask "Migrate them into ${app_pretty} (backed up first, old services kept for --rollback)?" Y; then
            migrate=yes
        else
            migrate=no
        fi
    fi

    mkdir -p "$app_dir"
    swizdb set "${app_name}/port" "$app_port"

    local apikey=""
    if [[ "$migrate" == "yes" && ${#sources[@]} -gt 0 ]]; then
        # Stop everything first so the backup and the copy are consistent
        for line in "${sources[@]}"; do
            if systemctl is-active -q "${line%%|*}"; then
                systemctl stop "${line%%|*}"
                _services_stopped+=("${line%%|*}")
            fi
        done
        _backup_sources "${sources[@]}"

        local main_dir="${sources[0]#*|}"
        echo_progress_start "Copying ${main_dir} into ${app_configdir}"
        mkdir -p "$app_configdir"
        cp -a "${main_dir}/." "$app_configdir"/
        rm -rf "${app_configdir}/log" "${app_configdir}/update"
        echo_progress_done "Config and database copied"
        apikey=$(_yaml_get "${main_dir}/config/config.yaml" auth.apikey)
        printf '%s\n' "backup=${backup_dest}" "${sources[@]}" >"$app_statefile"
        chmod 600 "$app_statefile"
    fi

    _write_listener_config
    chown -R "${user}:${user}" "$app_configdir"
    chmod 700 "$app_configdir"
    _copy_overlays
    _write_compose
    _start_stack

    if [[ -n "$apikey" ]]; then
        _wait_for_api "$apikey"
        local extra cfg
        for extra in "${sources[@]:1}"; do
            cfg="${extra#*|}/config/config.yaml"
            _add_arr_instances "$apikey" "$cfg" "$(basename "${extra#*|}" | sed 's/^bazarr-//' | tr '[:lower:]' '[:upper:]')"
        done
        for line in "${sources[@]}"; do
            systemctl disable -q "${line%%|*}" 2>/dev/null || true
        done
        echo_info "Old Bazarr services disabled (configs untouched): $(printf '%s ' "${sources[@]%%|*}")"
    fi
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_bazarrplus() {
    echo_progress_start "Installing systemd service"
    local mem_max="${SYSTEMD_MEM_MAX:-4G}"
    local cpu_quota="${SYSTEMD_CPU_QUOTA:-400%}"
    local tasks_max="${SYSTEMD_TASKS_MAX:-4096}"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty}
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
TimeoutStartSec=120
TimeoutStopSec=60

MemoryMax=${mem_max}
CPUQuota=${cpu_quota}
TasksMax=${tasks_max}
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    # Container is already up; mark the oneshot unit active without recreating
    systemctl start "$app_servicefile" >>"$log" 2>&1 || true
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
# Bazarr+ serves under its base_url, so the path is passed through unchanged.
# Protect it with Organizr via: bash organizr.sh --configure
_nginx_bazarrplus() {
    if [[ ! -f /install/.nginx.lock ]]; then
        echo_info "${app_pretty} will run on 127.0.0.1:${app_port}/${app_baseurl}"
        return 0
    fi
    echo_progress_start "Configuring nginx"
    cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
		location /${app_baseurl} {
		    return 301 /${app_baseurl}/;
		}

		location ^~ /${app_baseurl}/ {
		    proxy_pass http://127.0.0.1:${app_port}/${app_baseurl}/;
		    proxy_set_header Host \$host;
		    proxy_set_header X-Real-IP \$remote_addr;
		    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		    proxy_set_header X-Forwarded-Host \$host;
		    proxy_set_header X-Forwarded-Proto \$scheme;
		    proxy_redirect off;
		    proxy_http_version 1.1;
		    proxy_set_header Upgrade \$http_upgrade;
		    proxy_set_header Connection \$http_connection;
		    client_max_body_size 100m;

		    auth_basic "What's the password?";
		    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
		}

		# Bazarr+ authenticates its API with its own key
		location ^~ /${app_baseurl}/api {
		    auth_request off;
		    proxy_pass http://127.0.0.1:${app_port}/${app_baseurl}/api;
		    proxy_set_header Host \$host;
		    proxy_set_header X-Real-IP \$remote_addr;
		    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		    proxy_set_header X-Forwarded-Proto \$scheme;
		}
	NGX
    _nginx_config_written="/etc/nginx/apps/${app_name}.conf"
    _reload_nginx
    echo_progress_done "Nginx configured"

    local organizr_config="/opt/swizzin-extras/organizr-auth.conf"
    if [[ -f "$organizr_config" ]] && ! grep -q "^${app_name}:" "$organizr_config"; then
        echo "${app_name}:0" >>"$organizr_config"
        echo_info "Added ${app_name} to Organizr protected apps — apply with: bash organizr.sh --configure"
    fi
}

# ==============================================================================
# Rollback
# ==============================================================================
_rollback_bazarrplus() {
    if [[ ! -f "$app_statefile" ]]; then
        echo_error "No migration record at ${app_statefile} — nothing to roll back to"
        exit 1
    fi
    echo_info "Rolling back to the original Bazarr instances..."
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable -q "$app_servicefile" 2>/dev/null || true
    local line svc
    while read -r line; do
        [[ "$line" == backup=* || -z "$line" ]] && continue
        svc="${line%%|*}"
        systemctl enable -q "$svc" && systemctl start "$svc" && echo_info "Started ${svc}"
    done <"$app_statefile"
    echo_info "Backups remain at: $(grep '^backup=' "$app_statefile" | cut -d= -f2-)"
    echo_success "Rolled back — ${app_pretty} is stopped (remove it with --remove)"
    exit 0
}

# ==============================================================================
# Update
# ==============================================================================
_update_bazarrplus() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi
    echo_info "Updating ${app_pretty}..."
    _copy_overlays
    _write_compose
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    docker image prune -f >>"$log" 2>&1 || true
    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Removal
# ==============================================================================
_remove_bazarrplus() {
    local force="${1:-}" purgeconfig="false"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."
    if ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    fi

    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    docker rmi "$app_image" >>"$log" 2>&1 || true

    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload

    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        rm -f "/etc/nginx/apps/${app_name}.conf"
        _reload_nginx 2>/dev/null || true
    fi

    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        panel_unregister_app "$app_name"
    fi

    if [[ -f "$app_statefile" ]]; then
        echo_info "Original Bazarr services are still disabled; re-enable them with: bash $0 --rollback (before purging)"
    fi

    if [[ "$purgeconfig" == "true" ]]; then
        rm -rf "$app_dir"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        echo_info "Migration backups kept at: ${backup_root}"
    else
        echo_info "Configuration kept at: ${app_configdir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    rm -f "/install/.${app_lockname}.lock"
    echo_success "${app_pretty} has been removed"
    exit 0
}

_register_panel() {
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "$app_pretty" \
            "/${app_baseurl}" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    fi
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
        _remove_bazarrplus "${2:-}"
        ;;
    "--update")
        _update_bazarrplus
        ;;
    "--rollback")
        _rollback_bazarrplus
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
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _install_bazarrplus
    _systemd_bazarrplus
    _nginx_bazarrplus
fi

_register_panel
touch "/install/.${app_lockname}.lock"
_cleanup_needed=false

echo_success "${app_pretty} installed"
echo_info "Web UI: /${app_baseurl}/ (127.0.0.1:${app_port})"
[[ -f "$app_statefile" ]] && echo_info "Roll back to the original Bazarr with: bash $0 --rollback"
exit 0
