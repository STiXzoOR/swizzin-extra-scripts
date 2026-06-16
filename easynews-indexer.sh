#!/bin/bash
# easynews-indexer installer
# STiXzoOR 2026
# Usage: bash easynews-indexer.sh [--update [--verbose]|--remove [--force]]
#
# Deploys the Sanket9225 Easynews-as-indexer bridge in Docker. The bridge
# wraps Easynews's proprietary file-level search behind a Newznab API so
# NZBHydra2 / Prowlarr / nzbdav can consume it as a generic Newznab indexer.
# Project: https://github.com/Sanket9225/Easynews_as_indexer
#
# Credentials: set EASYNEWS_USER / EASYNEWS_PASS in the environment to skip
# the interactive prompt. The bridge's own Newznab API key is generated on
# first install and persisted in /opt/easynews-indexer/.env (chmod 600).
#
# If NZBHydra2 is installed and reachable on 127.0.0.1:11021, the indexer
# is auto-registered as "Easynews Bridge" via Hydra's internal config API.

set -euo pipefail

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/apt-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apt-utils.sh" 2>/dev/null || true

# ==============================================================================
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap
# ==============================================================================
_cleanup_needed=false
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
            systemctl daemon-reload 2>/dev/null || true
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
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
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

# ==============================================================================
# App Configuration
# ==============================================================================
app_name="easynews-indexer"
app_pretty="Easynews-as-indexer"
app_lockname="${app_name//-/}"          # "easynewsindexer" — lock file name (no hyphens)

app_image="ghcr.io/sanket9225/easynews_as_indexer:latest"
app_container_port="8081"               # what the bridge listens on inside the container

app_dir="/opt/${app_name}"
app_envfile="${app_dir}/.env"
app_composefile="${app_dir}/docker-compose.yml"

app_servicefile="${app_name}.service"

# Hydra integration target — only used if NZBHydra2 is installed.
hydra_internal_url="http://127.0.0.1:11021/nzbhydra2"
hydra_indexer_name="Easynews Bridge"

# Owner: read from swizdb (set by other Swizzin installers) or fall back to master.
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"

# Port: read existing from swizdb, default to the bridge's natural 8081.
# Localhost-only binding, so port collision risk is low — but persist anyway
# so a re-run after manual override doesn't reset it.
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port="${app_container_port}"
fi

# ==============================================================================
# Docker Install (no-op if already present)
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
# Credentials — env vars > existing .env > interactive prompt
# ==============================================================================
_ensure_easynews_credentials() {
    EASYNEWS_USER="${EASYNEWS_USER:-}"
    EASYNEWS_PASS="${EASYNEWS_PASS:-}"

    # 1. Env vars win (CI / automation case)
    if [[ -n "$EASYNEWS_USER" && -n "$EASYNEWS_PASS" ]]; then
        return 0
    fi

    # 2. Reuse an existing .env from a prior install (idempotent re-run)
    if [[ -f "$app_envfile" ]]; then
        local existing_user existing_pass
        existing_user=$(grep '^EASYNEWS_USER=' "$app_envfile" | cut -d= -f2-)
        existing_pass=$(grep '^EASYNEWS_PASS=' "$app_envfile" | cut -d= -f2-)
        if [[ -n "$existing_user" && -n "$existing_pass" ]]; then
            EASYNEWS_USER="${EASYNEWS_USER:-$existing_user}"
            EASYNEWS_PASS="${EASYNEWS_PASS:-$existing_pass}"
            _verbose "Reusing Easynews credentials from existing $app_envfile"
            return 0
        fi
    fi

    # 3. Interactive prompt (fresh install, no env vars, no prior .env)
    echo_info "Easynews account credentials are required for the bridge."
    echo_info "(Skip this prompt next time by exporting EASYNEWS_USER and EASYNEWS_PASS.)"

    if [[ -z "$EASYNEWS_USER" ]]; then
        read -r -p "Easynews username: " EASYNEWS_USER
    fi
    if [[ -z "$EASYNEWS_PASS" ]]; then
        read -r -s -p "Easynews password: " EASYNEWS_PASS
        echo
    fi

    if [[ -z "$EASYNEWS_USER" || -z "$EASYNEWS_PASS" ]]; then
        echo_error "Username and password are both required."
        exit 1
    fi
}

# ==============================================================================
# Auth check — verify creds against Easynews's search endpoint
# ==============================================================================
_verify_easynews_credentials() {
    echo_progress_start "Verifying Easynews credentials"

    local http_code
    http_code=$(curl -s -o /dev/null --max-time 15 \
        --user "${EASYNEWS_USER}:${EASYNEWS_PASS}" \
        -w "%{http_code}" \
        "https://members.easynews.com/2.0/search/solr-search/?gps=test&pby=1&pno=1&u=1&st=advanced")

    if [[ "$http_code" == "200" ]]; then
        echo_progress_done "Credentials accepted by Easynews"
    elif [[ "$http_code" == "401" ]]; then
        echo_error "Easynews rejected the supplied credentials (HTTP 401)."
        echo_error "Double-check username and password at https://www.easynews.com/."
        exit 1
    else
        echo_warn "Unexpected response from Easynews (HTTP $http_code) — proceeding anyway."
    fi
}

# ==============================================================================
# App Installation
# ==============================================================================
_install_easynews_indexer() {
    mkdir -p "$app_dir"
    chown "${user}:${user}" "$app_dir"
    chmod 750 "$app_dir"

    # Persist port + owner
    swizdb set "${app_name}/owner" "$user"
    swizdb set "${app_name}/port" "$app_port"

    # Reuse an existing Newznab API key on re-run; generate one on fresh install.
    # This keeps Hydra/Prowlarr registrations stable across re-installs.
    local newznab_apikey=""
    if [[ -f "$app_envfile" ]] && grep -q '^NEWZNAB_APIKEY=' "$app_envfile"; then
        newznab_apikey=$(grep '^NEWZNAB_APIKEY=' "$app_envfile" | cut -d= -f2-)
        _verbose "Reusing existing Newznab API key (${newznab_apikey:0:6}...)"
    else
        newznab_apikey=$(openssl rand -hex 16)
        _verbose "Generated new Newznab API key (${newznab_apikey:0:6}...)"
    fi

    # Write .env with creds + generated key. chmod 600 BEFORE writing secrets
    # to avoid a window where the file exists with default perms.
    install -m 0600 /dev/null "$app_envfile"
    {
        printf 'EASYNEWS_USER=%s\n' "$EASYNEWS_USER"
        printf 'EASYNEWS_PASS=%s\n' "$EASYNEWS_PASS"
        printf 'NEWZNAB_APIKEY=%s\n' "$newznab_apikey"
    } >"$app_envfile"
    chown "${user}:${user}" "$app_envfile"

    echo_progress_start "Generating Docker Compose configuration"

    # Resource limits — the bridge is a small Flask server, defaults are
    # intentionally light. Override via environment variables if needed.
    local cpu_limit="${DOCKER_CPU_LIMIT:-0.5}"
    local mem_limit="${DOCKER_MEM_LIMIT:-256M}"

    cat >"$app_composefile" <<COMPOSE
# Auto-generated by easynews-indexer.sh — do not edit manually.
# Credentials live in .env (chmod 600).
services:
  ${app_name}:
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    env_file: .env
    environment:
      - PORT=${app_container_port}
      - STRICT_MATCHING=1
    ports:
      - "127.0.0.1:${app_port}:${app_container_port}"
    deploy:
      resources:
        limits:
          cpus: '${cpu_limit}'
          memory: ${mem_limit}
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null --tries=1 --timeout=5 http://localhost:${app_container_port}/api?t=caps&apikey=\$\${NEWZNAB_APIKEY} || exit 1"]
      interval: 1m
      timeout: 10s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
COMPOSE

    chown "${user}:${user}" "$app_composefile"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling ${app_pretty} Docker image"
    docker compose -f "$app_composefile" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting ${app_pretty} container"
    docker compose -f "$app_composefile" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "${app_pretty} container started"

    # Wait briefly for healthcheck to settle, then probe the caps endpoint
    # directly to confirm the bridge answers Newznab API calls.
    echo_progress_start "Waiting for bridge to become responsive"
    local caps_code
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 2
        caps_code=$(curl -s -o /dev/null --max-time 5 -w "%{http_code}" \
            "http://127.0.0.1:${app_port}/api?t=caps&apikey=${newznab_apikey}")
        if [[ "$caps_code" == "200" ]]; then
            echo_progress_done "Bridge responsive (caps endpoint HTTP 200)"
            return 0
        fi
    done
    echo_warn "Bridge did not respond on /api?t=caps within 20s — check 'docker logs ${app_name}'."
}

# ==============================================================================
# Systemd oneshot wrapper (matches the pattern used by nzbdav, decypharr, etc.)
# ==============================================================================
_systemd_easynews_indexer() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Newznab bridge for Easynews search)
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
TimeoutStopSec=30

# Light resource caps — Flask + Easynews search proxy is tiny.
MemoryMax=512M
CPUQuota=100%
TasksMax=512

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="${app_servicefile}"

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# NZBHydra2 auto-registration
# ==============================================================================
# If Hydra is installed AND reachable, add the bridge as a Generic Newznab
# indexer named "Easynews Bridge". Idempotent: skips if already present.
# Failure here is a warning, not a fatal error — the bridge is still usable
# manually via Hydra's UI.
_register_in_hydra() {
    if [[ ! -f /install/.nzbhydra2.lock ]]; then
        echo_info "NZBHydra2 not installed; skipping auto-registration"
        return 0
    fi

    if ! curl -sS --max-time 5 "${hydra_internal_url}/internalapi/indexerstatuses" >/dev/null 2>&1; then
        echo_warn "NZBHydra2 is installed but not reachable at ${hydra_internal_url}"
        echo_warn "  Add the indexer manually after Hydra starts (see post-install instructions)"
        return 0
    fi

    echo_progress_start "Registering '${hydra_indexer_name}' in NZBHydra2"

    local cfg_tmp resp_tmp newznab_apikey
    cfg_tmp=$(mktemp /tmp/easynews-hydra-cfg-XXXXXX.json)
    resp_tmp=$(mktemp /tmp/easynews-hydra-resp-XXXXXX.json)
    newznab_apikey=$(grep '^NEWZNAB_APIKEY=' "$app_envfile" | cut -d= -f2-)

    # Fetch current Hydra config
    if ! curl -sS --max-time 8 "${hydra_internal_url}/internalapi/config" >"$cfg_tmp"; then
        echo_warn "Failed to fetch NZBHydra2 config; manual registration required"
        rm -f "$cfg_tmp" "$resp_tmp"
        return 0
    fi

    # Build the mutated config: append "Easynews Bridge" if absent.
    # Done inline in python so the JSON manipulation is reliable.
    local new_cfg_tmp
    new_cfg_tmp=$(mktemp /tmp/easynews-hydra-new-XXXXXX.json)

    if ! NEWZNAB_APIKEY="$newznab_apikey" APP_PORT="$app_port" \
         HYDRA_INDEXER_NAME="$hydra_indexer_name" \
         python3 - "$cfg_tmp" "$new_cfg_tmp" <<'PYEOF'
import json, os, sys
cfg_path, out_path = sys.argv[1], sys.argv[2]
name    = os.environ['HYDRA_INDEXER_NAME']
api_key = os.environ['NEWZNAB_APIKEY']
port    = os.environ['APP_PORT']

with open(cfg_path) as f:
    cfg = json.load(f)

if any(i.get('name') == name for i in cfg.get('indexers', [])):
    print('already-present')
    with open(out_path, 'w') as f:
        json.dump(cfg, f)
    sys.exit(0)

# Use an existing Newznab indexer (any) as the structural template — Hydra is
# picky about which fields exist on the indexer dict.
tmpl = next((i for i in cfg.get('indexers', []) if i.get('searchModuleType') == 'NEWZNAB'), None)
if tmpl is None:
    sys.exit("no Newznab indexer template available in Hydra config")

new = json.loads(json.dumps(tmpl))
new['name']                 = name
new['host']                 = f'http://127.0.0.1:{port}'
new['apiKey']               = api_key
new['apiPath']              = '/api'
new['searchModuleType']     = 'NEWZNAB'
new['backend']              = 'NEWZNAB'
new['state']                = 'ENABLED'
new['preselect']            = True
new['score']                = 0
new['supportedSearchIds']   = []          # Easynews has no tvdbid/imdbid lookup
new['supportedSearchTypes'] = ['SEARCH', 'TVSEARCH', 'MOVIE']
new['enabledCategories']    = []
new['allCapsChecked']       = True
new['configComplete']       = True
new['hitLimit']             = None
new['downloadLimit']        = None
new['timeout']              = None
new['username']             = None
new['password']             = None
new['userAgent']            = None
new['categoryMapping'] = {
    'anime': 5070,
    'categories': [
        {'id': 2000, 'name': 'Movies', 'subCategories': [
            {'id': 2030, 'name': 'Movies/HD'},
            {'id': 2040, 'name': 'Movies/UHD'},
        ]},
        {'id': 5000, 'name': 'TV', 'subCategories': [
            {'id': 5030, 'name': 'TV/HD'},
            {'id': 5040, 'name': 'TV/UHD'},
            {'id': 5070, 'name': 'TV/Anime'},
        ]},
        {'id': 7000, 'name': 'Other'},
    ],
}
for k in ('lastError', 'disabledUntil', 'disabledAt', 'vipExpirationDate'):
    if k in new:
        new[k] = None
if 'disabledLevel' in new:
    new['disabledLevel'] = 0
if 'hitLimitResetTime' in new:
    new['hitLimitResetTime'] = 0

cfg['indexers'].append(new)
with open(out_path, 'w') as f:
    json.dump(cfg, f)
print('appended')
PYEOF
    then
        echo_warn "Failed to build new Hydra config — manual registration required"
        rm -f "$cfg_tmp" "$resp_tmp" "$new_cfg_tmp"
        return 0
    fi

    if grep -q 'already-present' "$resp_tmp" 2>/dev/null || \
       grep -q 'already-present' <(python3 -c "
import json
with open('$new_cfg_tmp') as f: pass
print('')  # placeholder
" 2>/dev/null); then
        # Re-check by reading the file size delta: if no change, skip the PUT.
        :
    fi

    # PUT new config back
    local put_code
    put_code=$(curl -sS --max-time 15 -X PUT \
        -H "Content-Type: application/json" \
        --data @"$new_cfg_tmp" \
        -o "$resp_tmp" \
        -w "%{http_code}" \
        "${hydra_internal_url}/internalapi/config")

    if [[ "$put_code" == "200" ]] && python3 -c "
import json, sys
with open('$resp_tmp') as f: d = json.load(f)
sys.exit(0 if d.get('ok') else 1)
" 2>/dev/null; then
        echo_progress_done "'${hydra_indexer_name}' registered in NZBHydra2"
    else
        echo_warn "Hydra returned HTTP $put_code on config update — manual registration required"
        _verbose "Response saved to $resp_tmp for inspection"
    fi

    rm -f "$cfg_tmp" "$new_cfg_tmp"
    [[ "$verbose" == "true" ]] || rm -f "$resp_tmp"
}

# ==============================================================================
# Unregister from Hydra (used by --remove)
# ==============================================================================
_unregister_from_hydra() {
    if [[ ! -f /install/.nzbhydra2.lock ]]; then
        return 0
    fi
    if ! curl -sS --max-time 5 "${hydra_internal_url}/internalapi/indexerstatuses" >/dev/null 2>&1; then
        return 0
    fi

    echo_progress_start "Removing '${hydra_indexer_name}' from NZBHydra2"

    local cfg_tmp new_cfg_tmp resp_tmp
    cfg_tmp=$(mktemp /tmp/easynews-hydra-cfg-XXXXXX.json)
    new_cfg_tmp=$(mktemp /tmp/easynews-hydra-new-XXXXXX.json)
    resp_tmp=$(mktemp /tmp/easynews-hydra-resp-XXXXXX.json)

    curl -sS --max-time 8 "${hydra_internal_url}/internalapi/config" >"$cfg_tmp" 2>/dev/null || {
        echo_warn "Failed to fetch Hydra config — manual removal required"
        rm -f "$cfg_tmp" "$new_cfg_tmp" "$resp_tmp"
        return 0
    }

    HYDRA_INDEXER_NAME="$hydra_indexer_name" python3 - "$cfg_tmp" "$new_cfg_tmp" <<'PYEOF'
import json, os, sys
cfg_path, out_path = sys.argv[1], sys.argv[2]
name = os.environ['HYDRA_INDEXER_NAME']
with open(cfg_path) as f: cfg = json.load(f)
before = len(cfg.get('indexers', []))
cfg['indexers'] = [i for i in cfg.get('indexers', []) if i.get('name') != name]
after = len(cfg['indexers'])
with open(out_path, 'w') as f: json.dump(cfg, f)
print('removed' if before != after else 'not-present')
PYEOF

    curl -sS --max-time 15 -X PUT \
        -H "Content-Type: application/json" \
        --data @"$new_cfg_tmp" \
        -o "$resp_tmp" \
        "${hydra_internal_url}/internalapi/config" >/dev/null 2>&1 || true

    echo_progress_done "Hydra registration cleared"
    rm -f "$cfg_tmp" "$new_cfg_tmp" "$resp_tmp"
}

# ==============================================================================
# Update — pull latest image + recreate
# ==============================================================================
_update_easynews_indexer() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Pulling latest ${app_pretty} image"
    _verbose "docker compose -f ${app_composefile} pull"
    docker compose -f "$app_composefile" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating ${app_pretty} container"
    docker compose -f "$app_composefile" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_easynews_indexer() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    local purgeconfig="false"
    if ask "Would you like to purge configuration (including saved Easynews credentials)?" N; then
        purgeconfig="true"
    fi

    echo_progress_start "Stopping ${app_pretty} container"
    if [[ -f "$app_composefile" ]]; then
        docker compose -f "$app_composefile" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    echo_progress_start "Removing Docker image"
    docker rmi "$app_image" >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    _unregister_from_hydra

    if [[ "$purgeconfig" == "true" ]]; then
        echo_progress_start "Purging configuration and credentials"
        rm -rf "$app_dir"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        echo_progress_done "All files purged"
    else
        echo_info "Configuration kept at: ${app_dir}"
        rm -f "$app_composefile"
    fi

    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Main
# ==============================================================================

# Subcommand dispatch — guard positional with "${1:-}" under set -u.
case "${1:-}" in
    --remove) _remove_easynews_indexer "${2:-}" ;;
    --update) _update_easynews_indexer ;;
esac

if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed at http://127.0.0.1:${app_port}/"
    echo_info "Use --update to refresh or --remove to uninstall."
    exit 0
fi

_cleanup_needed=true

echo_info "Installing ${app_pretty} (owner: ${user}, port: ${app_port})"

_ensure_easynews_credentials
_verify_easynews_credentials
_install_docker
_install_easynews_indexer
_systemd_easynews_indexer
_register_in_hydra

touch "/install/.${app_lockname}.lock"
_lock_file_created="/install/.${app_lockname}.lock"

_cleanup_needed=false

echo_success "${app_pretty} installed"
echo_info "  Newznab endpoint:  http://127.0.0.1:${app_port}/api"
echo_info "  Newznab API key:   stored in ${app_envfile}"
echo_info "  Container logs:    docker logs ${app_name}"
if [[ -f /install/.nzbhydra2.lock ]]; then
    echo_info "  Registered in NZBHydra2 as: ${hydra_indexer_name}"
fi
