#!/bin/bash
set -euo pipefail
# nzbdav installer
# STiXzoOR 2026
# Usage: bash nzbdav.sh [--update [--verbose]|--remove [--force]|--register-panel]
#
# Builds infinidysk/infinidysk (InfiniDysk, the maintained community
# successor to nzbdav-dev/nzbdav; renamed from nzbdav/nzbdav in v1.0.0)
# from upstream release tags. Native NZBDAV_URL_BASE
# sub-path support merged upstream in v0.10.0 (PR #818), so no fork is
# needed anymore — but React Router's basename is build-time, so the
# prebuilt upstream images (root-hosted) still won't work for sub-path
# hosting without this local rebuild step baking our prefix in.
# Override NZBDAV_FORK_TAG=<tag|branch> to pin.

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
    # Prefer local repo copy (no network dependency, no supply chain risk)
    if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
        . "${SCRIPT_DIR}/panel_helpers.sh"
        return
    fi
    # Fallback to cached copy from a previous repo-based run
    if [[ -f "$PANEL_HELPER_CACHE" ]]; then
        . "$PANEL_HELPER_CACHE"
        return
    fi
    echo_info "panel_helpers.sh not found; skipping panel integration"
}

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_systemd_unit_written=""
_lock_file_created=""
app_mount_point=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
        # FUSE unmount cleanup
        if [[ -n "$app_mount_point" ]] && mountpoint -q "${app_mount_point}" 2>/dev/null; then
            fusermount -uz "${app_mount_point}" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/rclone-nzbdav.service" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        _reload_nginx 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

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
# Fork pinning
# ==============================================================================
# Builds upstream infinidysk/infinidysk directly (renamed from
# nzbdav/nzbdav in v1.0.0; the old path redirects during a transition
# period) — our NZBDAV_URL_BASE sub-path patch merged in v0.10.0
# (https://github.com/infinidysk/infinidysk/pull/818). The Dockerfile
# kept the NZBDAV_URL_BASE / NZBDAV_VERSION build-args through the
# rename, so the local rebuild flow is unchanged.
# By default the newest upstream release tag is resolved at run time so
# `--update` keeps picking up releases without manual bumps; the fallback
# pin below is used when the GitHub API is unreachable. Upstream also
# maintains a movable `lts` git tag (conservative channel) — set
# NZBDAV_FORK_TAG=lts to track it instead.
#
# NZBDAV_URL_BASE bakes the React Router basename, Vite asset base, and
# the `__URL_BASE__` JS constant into the client bundle (build-time). The
# runtime env var in the compose file must match — the app refuses to
# start on a mismatch; see docs/configuration/url-base.md upstream.
# Upstream's published images ship root-hosted (no URL_BASE), which is
# why this installer builds locally with our prefix baked in instead of
# pulling.

NZBDAV_FORK_REPO="infinidysk/infinidysk"
NZBDAV_FALLBACK_TAG="v1.2.4"
if [[ -z "${NZBDAV_FORK_TAG:-}" ]]; then
    NZBDAV_FORK_TAG=$(curl -sf --max-time 10 "https://api.github.com/repos/${NZBDAV_FORK_REPO}/releases/latest"         | grep -oP '"tag_name":\s*"\K[^"]+' || true)
    NZBDAV_FORK_TAG="${NZBDAV_FORK_TAG:-${NZBDAV_FALLBACK_TAG}}"
fi
NZBDAV_URL_BASE="/nzbdav"

# ==============================================================================
# App Configuration
# ==============================================================================

app_name="nzbdav"
app_pretty="NZBDav"
app_lockname="${app_name}"
app_baseurl="${app_name}"
app_image="nzbdav-stixzoor:${NZBDAV_FORK_TAG//\//-}"
app_dir="/opt/nzbdav"
app_configdir="${app_dir}/config"
app_servicefile="${app_name}.service"
app_mount_servicefile="rclone-nzbdav.service"
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/nzb-dav.png"
app_default_mount="/mnt/nzbdav"
app_reqs=("curl" "fuse3" "sqlite3")

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Port persistence - read existing port from swizdb, allocate only on fresh install
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

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

    # Source os-release once for distro detection
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

    # Use apt-get directly instead of apt_install — Docker's post-install
    # triggers service restarts that Swizzin's apt_install treats as errors
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }

    systemctl enable --now docker >>"$log" 2>&1

    # Verify Docker is running
    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_progress_done "Docker installed"
}

# ==============================================================================
# rclone Installation
# ==============================================================================
_install_rclone() {
    if command -v rclone &>/dev/null; then
        local current_version
        current_version=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
        echo_info "rclone $current_version already installed"
        return 0
    fi

    echo_progress_start "Installing rclone"
    # The official install script may return non-zero if already latest
    curl -fsSL https://rclone.org/install.sh | bash >>"$log" 2>&1 || true

    # Verify rclone is now available
    if command -v rclone &>/dev/null; then
        echo_progress_done "rclone installed: $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
    else
        echo_error "Failed to install rclone"
        exit 1
    fi
}

# ==============================================================================
# FUSE Configuration
# ==============================================================================
_configure_fuse() {
    if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
        echo "user_allow_other" >>/etc/fuse.conf
    fi
}

# ==============================================================================
# Mount Point Configuration
# ==============================================================================
_get_mount_point() {
    # Skip if already set
    if [[ -n "$app_mount_point" ]]; then
        echo_info "Using mount point: $app_mount_point"
        return
    fi

    # Check environment variable first
    if [[ -n "${NZBDAV_MOUNT_PATH:-}" ]]; then
        echo_info "Using mount point from NZBDAV_MOUNT_PATH: $NZBDAV_MOUNT_PATH"
        app_mount_point="$NZBDAV_MOUNT_PATH"
        return
    fi

    # Check existing config in swizdb
    local existing_mount
    existing_mount=$(swizdb get "${app_name}/mount_point" 2>/dev/null) || true

    local default_mount="${existing_mount:-$app_default_mount}"

    echo_query "Enter NZBDav mount point" "[$default_mount]"
    read -r input_mount </dev/tty

    if [[ -z "$input_mount" ]]; then
        app_mount_point="$default_mount"
    else
        # Validate absolute path
        if [[ ! "$input_mount" = /* ]]; then
            echo_error "Mount point must be an absolute path (start with /)"
            exit 1
        fi
        app_mount_point="$input_mount"
    fi

    echo_info "Using mount point: $app_mount_point"
}

# ==============================================================================
# Fork build (clone + docker build with URL_BASE baked in)
# ==============================================================================
# Builds ${app_image} locally from ${NZBDAV_FORK_REPO}@${git_ref} with
# URL_BASE=${NZBDAV_URL_BASE} as a build arg. React Router v7's basename is
# build-time only, so the prebuilt fork image ships with URL_BASE='' and any
# sub-path deployment has to rebake the image — that's us.
#
# Versioned tags (0.6.7 / v0.6.7) skip rebuild if the image is already present;
# moving tags (latest / pre-release / alpha / *.x) always rebuild so `--update`
# actually picks up new commits when release.yml repoints the tag. To force
# a rebuild on a version pin, `docker rmi ${app_image}` first.
_build_nzbdav_image() {
    # Versioned tag → prefix with `v`; moving tag → use as-is.
    local git_ref
    if [[ "${NZBDAV_FORK_TAG}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        git_ref="v${NZBDAV_FORK_TAG#v}"
        if docker image inspect "${app_image}" >/dev/null 2>&1; then
            _verbose "Image ${app_image} already built (pinned tag) — skipping rebuild"
            return 0
        fi
    else
        git_ref="${NZBDAV_FORK_TAG}"
        if docker image inspect "${app_image}" >/dev/null 2>&1; then
            _verbose "Image ${app_image} present but tracking moving tag '${NZBDAV_FORK_TAG}' — rebuilding"
        fi
    fi

    echo_progress_start "Building ${app_pretty} image from ${git_ref} (URL_BASE=${NZBDAV_URL_BASE})"

    local tmp
    tmp=$(mktemp -d -t nzbdav-build.XXXXXX) || {
        echo_error "Failed to create temp build dir"
        return 1
    }

    local rc=0
    (
        _verbose "Cloning https://github.com/${NZBDAV_FORK_REPO} at ${git_ref} into $tmp"
        git -c advice.detachedHead=false clone --depth 1 \
            --recurse-submodules --shallow-submodules \
            --branch "${git_ref}" \
            "https://github.com/${NZBDAV_FORK_REPO}" "$tmp" >>"$log" 2>&1 || exit 1

        _verbose "Running: docker build --build-arg NZBDAV_URL_BASE=${NZBDAV_URL_BASE} -t ${app_image} $tmp"
        docker build \
            --build-arg "NZBDAV_URL_BASE=${NZBDAV_URL_BASE}" \
            --build-arg "NZBDAV_VERSION=${NZBDAV_FORK_TAG}" \
            --build-arg "REPO_URL=https://github.com/${NZBDAV_FORK_REPO}" \
            -t "${app_image}" "$tmp" >>"$log" 2>&1 || exit 1
    ) || rc=$?

    rm -rf "$tmp"

    if (( rc != 0 )); then
        echo_error "Failed to build ${app_image} (see $log for details)"
        return 1
    fi

    echo_progress_done "Built ${app_image}"
}

# ==============================================================================
# NZBDav Health Check & Internal API
# ==============================================================================
_wait_for_health() {
    local max_wait="${1:-60}"
    local interval=2
    local elapsed=0
    while (( elapsed < max_wait )); do
        # /healthz is served at the unprefixed root by the frontend even when
        # URL_BASE is set — it proxies to the backend's own health and
        # surfaces the result. Keeps everything on the frontend port so the
        # backend's 8080 stays purely internal.
        if curl -sf "http://127.0.0.1:${app_port}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        (( elapsed += interval )) || true
    done
    return 1
}

# POST config updates to NZBDav's internal API
# Usage: _nzbdav_api_post "config.key" "value" ["key2" "value2" ...]
_nzbdav_api_post() {
    local api_key
    api_key=$(docker exec nzbdav printenv FRONTEND_BACKEND_API_KEY 2>/dev/null) || return 1

    local form_args=()
    while [[ $# -gt 0 ]]; do
        form_args+=(-F "configName=$1" -F "configValue=$2")
        shift 2
    done

    # /nzbdav/api/update-config when URL_BASE is set, /api/update-config when
    # it isn't. The frontend proxies /api through to the backend either way.
    curl -sf -X POST "http://127.0.0.1:${app_port}${NZBDAV_URL_BASE}/api/update-config" \
        -H "x-api-key: ${api_key}" \
        "${form_args[@]}" >/dev/null 2>&1
}

# ==============================================================================
# Docker Compose / Container
# ==============================================================================
_install_nzbdav() {
    mkdir -p "$app_configdir"
    chmod 700 "$app_configdir"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    # Persist port in swizdb
    swizdb set "${app_name}/port" "$app_port"

    echo_progress_start "Generating Docker Compose configuration"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  nzbdav:
    image: ${app_image}
    container_name: nzbdav
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - PORT=${app_port}
      - NZBDAV_URL_BASE=${NZBDAV_URL_BASE}
    volumes:
      - ${app_configdir}:/config
      - /mnt:/mnt:rslave
    healthcheck:
      # Hit the frontend's /healthz endpoint — it's served at the unprefixed
      # root regardless of URL_BASE (the old /health path now 302s to login,
      # which curl -f would wrongly treat as healthy).
      test: ["CMD", "curl", "-f", "http://localhost:${app_port}/healthz"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
COMPOSE

    echo_progress_done "Docker Compose configuration generated"
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

    _build_nzbdav_image || exit 1

    echo_progress_start "Starting ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "${app_pretty} container started"
}

# ==============================================================================
# Systemd Services
# ==============================================================================
_systemd_nzbdav() {
    echo_progress_start "Installing systemd service for Docker container"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (WebDAV server for Usenet streaming)
Requires=docker.service
After=docker.service
Wants=${app_mount_servicefile}

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="${app_servicefile}"
    systemctl -q daemon-reload
    systemctl enable -q "${app_servicefile}"
    echo_progress_done "Docker systemd service installed and enabled"
}

_systemd_rclone_nzbdav() {
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    echo_progress_start "Installing rclone mount systemd service"

    cat >"/etc/systemd/system/${app_mount_servicefile}" <<EOF
[Unit]
Description=rclone NZBDav WebDAV mount
After=nzbdav.service
BindsTo=nzbdav.service

[Service]
Type=notify
User=${user}
Group=${user}
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do curl -sf http://127.0.0.1:${app_port}/healthz && exit 0; sleep 2; done; echo "NZBDav health check timed out after 60s"; exit 1'
ExecStart=/usr/bin/rclone mount nzbdav: ${app_mount_point} \
    --config ${app_dir}/rclone.conf \
    --uid ${uid} --gid ${gid} \
    --allow-other \
    --links \
    --use-cookies \
    --vfs-cache-mode full \
    --buffer-size 32M \
    --vfs-read-ahead 512M \
    --vfs-cache-max-size 20G \
    --vfs-cache-min-free-space 15G \
    --vfs-cache-max-age 24h \
    --dir-cache-time 5m \
    --attr-timeout 1m \
    --poll-interval 15s
ExecStop=/bin/fusermount -uz ${app_mount_point}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    echo_progress_done "rclone mount systemd service installed (not yet enabled)"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
# Native URL_BASE support in the fork makes the proxy config a plain pass-through
# — no sub_filter, no proxy_redirect, no njs __manifest rewriter. The container
# emits correctly-prefixed URLs at the source. We forward the full URL_BASE path
# to it (proxy_pass without trailing slash so /${app_baseurl}/foo stays intact).
_nginx_nzbdav() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        # If the current config is protected by Organizr SSO, capture the auth
        # level so we can re-apply the swap after regenerating. Otherwise the
        # regen falls back to plain auth_basic and the user silently loses SSO.
        # Same pattern as decypharr.sh — see _apply_organizr_swap below.
        local nginx_conf="/etc/nginx/apps/${app_name}.conf"
        local organizr_auth_level=""
        if grep -q "auth_request /organizr-auth/auth-" "$nginx_conf" 2>/dev/null; then
            organizr_auth_level=$(grep -oE "auth_request /organizr-auth/auth-[0-9]+" "$nginx_conf" \
                | grep -oE '[0-9]+$' | head -1 || true)
            organizr_auth_level="${organizr_auth_level:-0}"
            _verbose "Detected Organizr SSO (auth-level ${organizr_auth_level}) — will re-apply after regen"
        fi

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location = /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    # No trailing slash on proxy_pass: forward the full /${app_baseurl}/... path so
			    # the container's URL_BASE mount lines up. The container's React Router basename
			    # and Vite asset base are baked at build time to /${app_baseurl}.
			    proxy_pass http://127.0.0.1:${app_port};
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # WebDAV range reads can take a while; keep them flowing intact.
			    proxy_buffering off;
			    proxy_read_timeout 6h;
			    proxy_send_timeout 6h;
			    client_max_body_size 0;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			# SABnzbd-compatible API: Sonarr/Radarr authenticate with the api key,
			# bypass the proxy-level basic auth here. Override client_max_body_size
			# at the location level too — the ^~ /nzbdav/api block is more specific
			# than /nzbdav/, so inheriting from there isn't enough, and the default
			# snippets/proxy.conf caps at 40m which kills NZB uploads.
			location ^~ /${app_baseurl}/api {
			    auth_basic   off;
			    auth_request off;
			    client_max_body_size 0;
			    proxy_pass http://127.0.0.1:${app_port};
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			}
		NGX

        _nginx_config_written="/etc/nginx/apps/${app_name}.conf"

        # Clean up legacy artifacts from the pre-native-URL_BASE config:
        rm -f /etc/nginx/njs.d/nzbdav_manifest.js 2>/dev/null || true
        rm -f /etc/nginx/modules-enabled/50-mod-http-js.conf 2>/dev/null || true
        sed -i '/njs scripts for NZBDav React Router support/,/subrequest_output_buffer_size 4k;/d' \
            /etc/nginx/nginx.conf 2>/dev/null || true
        sed -i '/js_import nzbdav from \/etc\/nginx\/njs.d\/nzbdav_manifest.js;/d' \
            /etc/nginx/nginx.conf 2>/dev/null || true

        # Re-apply Organizr SSO swap if the previous config used it.
        if [[ -n "$organizr_auth_level" ]]; then
            _apply_organizr_swap "$organizr_auth_level"
        fi

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} will run on port ${app_port}"
    fi
}

# ==============================================================================
# Replicate organizr.sh's _protect_app swap on a freshly-generated nginx block:
#   - comment out auth_basic + auth_basic_user_file (UI block)
#   - insert auth_request inside the top-level /${app_baseurl}/ UI location only
#     (never inside the /api/ block — that stays open for Sonarr/Radarr)
# Called by _nginx_nzbdav when the previous config was SSO-protected.
# ==============================================================================
_apply_organizr_swap() {
    local auth_level="$1"
    local nginx_conf="/etc/nginx/apps/${app_name}.conf"
    [[ -f "$nginx_conf" ]] || return 0

    sed -i 's|^\([[:space:]]*auth_basic \)|#\1|g' "$nginx_conf"
    sed -i 's|^\([[:space:]]*auth_basic_user_file\)|#\1|g' "$nginx_conf"
    # Match the exact opening line of the UI block the installer emits.
    sed -i "/^location \^~ \/${app_baseurl}\/ {\$/a\\    auth_request /organizr-auth/auth-${auth_level};" "$nginx_conf"
    echo_info "Re-applied Organizr SSO (auth-level ${auth_level})"
}

# ==============================================================================
# rclone Setup (auto-configures WebDAV credentials via internal API)
# ==============================================================================
_setup_rclone() {
    echo_info "Setting up rclone WebDAV mount for ${app_pretty}..."

    # Get or confirm mount point
    _get_mount_point
    swizdb set "${app_name}/mount_point" "$app_mount_point"

    local webdav_pass="" api_setup=false

    # Try automated setup via internal API
    if _wait_for_health 60; then
        webdav_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

        if _nzbdav_api_post "webdav.user" "admin" "webdav.pass" "${webdav_pass}"; then
            api_setup=true
            echo_info "WebDAV credentials configured automatically"

            # Tell NZBDav where the rclone mount lives (Phase 3)
            _nzbdav_api_post "rclone.mount-dir" "${app_mount_point}" || true
        fi
    fi

    # Fallback: manual prompt (re-run path or API failure)
    if [[ "$api_setup" == "false" ]]; then
        echo_warn "Automatic WebDAV setup unavailable — falling back to manual configuration."
        echo_query "Enter NZBDav WebDAV password (configured in the web UI)" ""
        read -rs webdav_pass </dev/tty
        echo ""

        if [[ -z "$webdav_pass" ]]; then
            echo_error "WebDAV password cannot be empty"
            exit 1
        fi
    fi

    # Obscure the password for rclone config
    echo_progress_start "Configuring rclone"
    local obscured
    obscured=$(echo "$webdav_pass" | rclone obscure -) || {
        echo_error "Failed to obscure password"
        exit 1
    }
    unset webdav_pass

    # Write rclone.conf with restricted permissions. Connects directly to
    # the backend (port 8080) — NWebDav doesn't honor ASP.NET's UsePathBase
    # in this version, so PROPFIND HREFs are root-relative regardless of
    # URL_BASE. Going through the frontend (${app_port}${NZBDAV_URL_BASE}/)
    # would land rclone with HREFs that don't match its base URL and silently
    # drop every entry. Hitting the backend at root sidesteps that until the
    # library learns about PathBase upstream.
    (
        umask 077
        cat >"${app_dir}/rclone.conf" <<RCLONE
[nzbdav]
type = webdav
url = http://127.0.0.1:8080/
vendor = other
user = admin
pass = ${obscured}
RCLONE
    )
    chown "${user}:${user}" "${app_dir}/rclone.conf"
    echo_progress_done "rclone configured"

    # Create mount point
    if [[ ! -d "$app_mount_point" ]]; then
        mkdir -p "$app_mount_point"
    fi
    chown "${user}:${user}" "$app_mount_point"

    # Write (or update) rclone mount systemd service
    _systemd_rclone_nzbdav

    # Enable and start rclone mount
    echo_progress_start "Starting rclone mount"
    systemctl enable --now -q "${app_mount_servicefile}"
    echo_progress_done "rclone mount started"

    echo_success "rclone WebDAV mount configured at ${app_mount_point}"
}

# ==============================================================================
# Post-Install Messaging
# ==============================================================================
_post_install_message() {
    echo ""
    echo_info "============================================"
    echo_info " ${app_pretty} Installation Complete"
    echo_info "============================================"
    echo ""

    if [[ -f "${app_dir}/rclone.conf" ]]; then
        echo_info "Auto-configured:"
        echo_info "  WebDAV credentials (admin / random password)"
        echo_info "  rclone mount at ${app_mount_point}"
        echo_info "  rclone config at ${app_dir}/rclone.conf"
    else
        echo_info "rclone mount not yet configured."
        echo_info "Re-run: bash ${SCRIPT_DIR}/${app_name}.sh"
    fi

    echo ""
    echo_warn "REMAINING SETUP (web UI required):"
    echo_info "  1. Open: https://your-server/${app_baseurl}/"
    echo_info "  2. Configure your Usenet provider in Settings > Usenet"
    echo_info "  3. Review SABnzbd settings in Settings > SABnzbd"
    echo ""
    echo_info "SABnzbd API: http://127.0.0.1:${app_port}/api"
    echo_info "API Key: check NZBDav Settings > SABnzbd after first-run setup"
    echo_info "Arr connections use: http://127.0.0.1:<arr_port>"
    echo ""
}

# ==============================================================================
# Fresh Install
# ==============================================================================
_install_fresh() {
    _cleanup_needed=true

    # Install dependencies
    apt_install "${app_reqs[@]}"

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    _install_docker
    _install_rclone
    _configure_fuse
    _install_nzbdav
    _systemd_nzbdav
    _nginx_nzbdav

    # Mark v0.6.0 migration as complete (fresh installs don't need it)
    touch "${app_configdir}/.v060-migrated"

    # Wait for container health before auto-configuration
    echo_progress_start "Waiting for ${app_pretty} to be ready"
    if _wait_for_health 60; then
        echo_progress_done "${app_pretty} is ready"
    else
        echo_warn "${app_pretty} health check timed out"
    fi

    # Auto-configure WebDAV credentials + rclone mount
    _setup_rclone

    # Panel registration
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

    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
    _cleanup_needed=false

    echo_success "${app_pretty} installed"
    _post_install_message
}

# ==============================================================================
# Update
# ==============================================================================
# Copy the config dir for rollback: everything real-copied except blobs/, which
# is hardlinked (write-once files; near-zero disk and seconds instead of minutes).
_backup_configdir() {
    local src="$1" dest="$2"
    mkdir -p "$dest" || return 1
    local entry
    for entry in "$src"/* "$src"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        if [[ "$(basename "$entry")" == "blobs" && -d "$entry" ]]; then
            cp -al "$entry" "$dest/blobs" || return 1
        else
            cp -a "$entry" "$dest/" || return 1
        fi
    done
    return 0
}

_update_nzbdav() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    # Back up config before update (keep only the newest backup).
    # blobs/ holds the NZB segment metadata and is nearly all of the config dir
    # on a mature install (tens of GB). It is also write-once: an upgrade never
    # rewrites a blob, and the image swap doesn't touch the volume at all. A
    # real copy would double the config dir on disk and take many minutes for
    # nothing, so hardlink it and real-copy the rest (db.sqlite is written in
    # place, so it must be a true copy for a rollback to work).
    local backup_dir="${app_configdir}.bak.$(date +%Y%m%d%H%M%S)"
    if _backup_configdir "${app_configdir}" "$backup_dir"; then
        echo_info "Config backed up to ${backup_dir}"
        find "$(dirname "${app_configdir}")" -maxdepth 1 -type d \
            -name "$(basename "${app_configdir}").bak.*" \
            ! -path "${backup_dir}" -exec rm -rf {} + 2>/dev/null || true
    fi

    # Save rclone mount state before update
    local rclone_was_active
    rclone_was_active=$(systemctl is-active "${app_mount_servicefile}" 2>/dev/null) || rclone_was_active="inactive"

    # Stop rclone mount first (unmount before stopping backend)
    if [[ "$rclone_was_active" == "active" ]]; then
        echo_progress_start "Stopping rclone mount"
        systemctl stop "${app_mount_servicefile}" 2>/dev/null || true
        echo_progress_done "rclone mount stopped"
    fi

    # Regenerate compose file (picks up host networking/PORT changes from installer updates)
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    echo_progress_start "Updating Docker Compose configuration"
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  nzbdav:
    image: ${app_image}
    container_name: nzbdav
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - PORT=${app_port}
      - NZBDAV_URL_BASE=${NZBDAV_URL_BASE}
    volumes:
      - ${app_configdir}:/config
      - /mnt:/mnt:rslave
    healthcheck:
      # Hit the frontend's /healthz endpoint — it's served at the unprefixed
      # root regardless of URL_BASE (the old /health path now 302s to login,
      # which curl -f would wrongly treat as healthy).
      test: ["CMD", "curl", "-f", "http://localhost:${app_port}/healthz"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
COMPOSE
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"
    echo_progress_done "Docker Compose configuration updated"

    _build_nzbdav_image || exit 1

    # Handle v0.6.0 migration (one-time, irreversible DB migration)
    if [[ ! -f "${app_configdir}/.v060-migrated" ]]; then
        echo_warn "Applying v0.6.0 database migration (one-time, irreversible)..."
        # Temporarily add UPGRADE env var
        sed -i '/- PGID=/a\      - UPGRADE=0.6.0' "${app_dir}/docker-compose.yml"

        docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
            echo_error "Failed to start v0.6.0 migration"
            exit 1
        }
        _wait_for_health 120 || echo_warn "Health check timed out during migration"

        # Remove UPGRADE env var and recreate cleanly
        sed -i '/- UPGRADE=0.6.0/d' "${app_dir}/docker-compose.yml"
        touch "${app_configdir}/.v060-migrated"
        echo_info "v0.6.0 migration complete"
    fi

    echo_progress_start "Recreating ${app_pretty} container"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    # Refresh nginx config — the proxy template can change between releases
    # (e.g. native URL_BASE support replaced the sub_filter-heavy block with a
    # plain pass-through). _nginx_nzbdav is idempotent: it rewrites the same
    # /etc/nginx/apps/${app_name}.conf, scrubs the obsolete njs artifacts, and
    # reloads nginx if anything changed.
    _nginx_nzbdav

    # Restart rclone mount if it was active.
    #
    # The mount can only attach once the backend WebDAV is actually serving, and
    # a freshly-recreated container needs time to boot + run EF migrations. Starting
    # the mount immediately (and swallowing failures with `|| true`) raced the
    # backend, so rclone failed to connect, the unit went to `failed`, and the mount
    # was silently left down after the update. Wait for health, then start with
    # retries and verify it actually came up instead of reporting a false success.
    if [[ "$rclone_was_active" == "active" ]]; then
        echo_progress_start "Waiting for backend before remounting"
        _wait_for_health 120 || echo_warn "Health check timed out; attempting mount anyway"
        echo_progress_done "Backend ready"

        # Resolve the mount point for verification (not re-derived in this function).
        local _mp="${app_mount_point}"
        [[ -z "$_mp" ]] && _mp=$(swizdb get "${app_name}/mount_point" 2>/dev/null) || true

        echo_progress_start "Restarting rclone mount"
        local _mount_ok=false _try
        for _try in 1 2 3; do
            systemctl reset-failed "${app_mount_servicefile}" 2>/dev/null || true
            systemctl start "${app_mount_servicefile}" 2>/dev/null || true
            sleep 3
            if systemctl is-active --quiet "${app_mount_servicefile}" \
                && { [[ -z "$_mp" ]] || mountpoint -q "$_mp" 2>/dev/null; }; then
                _mount_ok=true
                break
            fi
            _verbose "rclone mount not ready (attempt ${_try}/3); retrying"
        done
        if [[ "$_mount_ok" == true ]]; then
            echo_progress_done "rclone mount restarted"
        else
            echo_error "rclone mount did not come back up. Recover with: systemctl reset-failed ${app_mount_servicefile} && systemctl start ${app_mount_servicefile}"
        fi
    fi

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_nzbdav() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Get mount point from swizdb (needed for unmounting)
    app_mount_point=$(swizdb get "${app_name}/mount_point" 2>/dev/null) || app_mount_point="$app_default_mount"

    # Ask about purging configuration (skip prompt if --force)
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # 1. Stop rclone mount FIRST (unmount before stopping backend)
    if [[ -f "/etc/systemd/system/${app_mount_servicefile}" ]]; then
        echo_progress_start "Stopping rclone mount service"
        systemctl stop "${app_mount_servicefile}" 2>/dev/null || true
        systemctl disable "${app_mount_servicefile}" 2>/dev/null || true
        echo_progress_done "rclone mount service stopped"
    fi

    # 2. Cleanup stale FUSE mount
    if mountpoint -q "$app_mount_point" 2>/dev/null; then
        echo_progress_start "Unmounting ${app_mount_point}"
        fusermount -uz "$app_mount_point" 2>/dev/null || umount -f "$app_mount_point" 2>/dev/null || true
        echo_progress_done "Unmounted"
    fi

    # 3. Stop Docker container
    echo_progress_start "Stopping ${app_pretty} container"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi "${app_image}" >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    # 4. Remove both systemd services
    echo_progress_start "Removing systemd services"
    systemctl stop "${app_servicefile}" 2>/dev/null || true
    systemctl disable "${app_servicefile}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    rm -f "/etc/systemd/system/${app_mount_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Services removed"

    # 5. Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        _remove_nginx_conf "$app_name"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # 6. Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # 7. Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        # Remove rclone VFS cache
        local vfs_cache="/home/${user}/.cache/rclone/vfs/nzbdav"
        if [[ -d "$vfs_cache" ]]; then
            local cache_size
            cache_size=$(du -sh "$vfs_cache" 2>/dev/null | cut -f1) || cache_size="unknown"
            rm -rf "$vfs_cache"
            echo_info "Cleared VFS cache ($cache_size freed)"
        fi
        # Remove app directory (config, rclone.conf, docker-compose.yml)
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        swizdb clear "${app_name}/mount_point" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_configdir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    # Remove mount point directory if empty
    if [[ -d "$app_mount_point" ]]; then
        rmdir "$app_mount_point" 2>/dev/null || true
    fi

    # 8. Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Usage
# ==============================================================================
_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  (no args)             Install / re-run to set up rclone mount"
    echo "  --update [--verbose]  Pull latest Docker image"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
}

# ==============================================================================
# Main
# ==============================================================================

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

case "${1:-}" in
    "--update")
        _update_nzbdav
        ;;
    "--remove")
        _remove_nzbdav "${2:-}"
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
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
            systemctl restart panel 2>/dev/null || true
            echo_success "Panel registration updated for ${app_pretty}"
        else
            echo_error "Panel helper not available"
            exit 1
        fi
        exit 0
        ;;
    "")
        # Default: install or re-run
        if [[ -f "/install/.${app_lockname}.lock" ]]; then
            # Re-run: check if rclone needs setup
            if [[ ! -f "${app_dir}/rclone.conf" ]]; then
                _setup_rclone
            else
                echo_info "${app_pretty} already installed, restarting services"
                systemctl restart "${app_servicefile}" 2>/dev/null || true
                systemctl restart "${app_mount_servicefile}" 2>/dev/null || true
            fi

            # Re-register panel on every re-run
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
            exit 0
        fi

        # Fresh install
        _install_fresh
        ;;
    *)
        _usage
        ;;
esac
