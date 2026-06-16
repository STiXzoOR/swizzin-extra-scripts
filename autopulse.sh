#!/bin/bash
set -euo pipefail
# autopulse installer
# STiXzoOR 2026
# Usage: bash autopulse.sh [--update [--verbose]|--remove [--force]|--register-panel]

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
# App Configuration
# ==============================================================================

app_name="autopulse"
app_pretty="Autopulse"
app_lockname="${app_name}"
app_baseurl="${app_name}"
app_image_api="ghcr.io/dan-online/autopulse:latest"
app_image_ui="ghcr.io/dan-online/autopulse:ui-dynamic"

app_dir="/opt/${app_name}"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/autopulse.png"

# Host paths to bind-mount into the autopulse container so its file-existence
# check (stat) can see paths the *arrs send via webhooks.  Populated by
# _resolve_media_paths.  Without these, every event lands as found_status=
# not_found, suppressing retries and producing silent target failures.
MEDIA_PATHS=()

# ==============================================================================
# User/Owner Setup
# ==============================================================================

if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
	app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Port persistence — API port
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
	app_port="$_existing_port"
elif [[ -n "${AUTOPULSE_PORT:-}" ]]; then
	app_port="$AUTOPULSE_PORT"
else
	app_port=$(port 10000 12000)
fi

# Port persistence — UI port
if _existing_ui_port="$(swizdb get "${app_name}/ui_port" 2>/dev/null)" && [[ -n "$_existing_ui_port" ]]; then
	app_ui_port="$_existing_ui_port"
elif [[ -n "${AUTOPULSE_UI_PORT:-}" ]]; then
	app_ui_port="$AUTOPULSE_UI_PORT"
else
	app_ui_port=$(port 10000 12000)
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
# Ensure jq is available (needed for API interactions)
# ==============================================================================
_ensure_jq() {
	if command -v jq >/dev/null 2>&1; then
		return 0
	fi
	echo_progress_start "Installing jq"
	apt_install jq
	echo_progress_done "jq installed"
}

# ==============================================================================
# Arr Instance Auto-Discovery
# ==============================================================================

# Parallel arrays populated by _discover_arrs
ARR_NAMES=()
ARR_TYPES=()    # "sonarr" or "radarr" or "lidarr" or "readarr"
ARR_PORTS=()
ARR_APIKEYS=()
ARR_URLBASES=()

_discover_arrs() {
	echo_progress_start "Discovering arr instances"

	local lock_basename config_dir_name arr_type instance_name
	local cfg port apikey urlbase

	for lock in /install/.sonarr.lock /install/.sonarr_*.lock \
		/install/.radarr.lock /install/.radarr_*.lock \
		/install/.lidarr.lock /install/.lidarr_*.lock \
		/install/.readarr.lock /install/.readarr_*.lock; do
		[[ -f "$lock" ]] || continue

		lock_basename=$(basename "$lock" .lock)
		lock_basename="${lock_basename#.}" # Remove leading dot

		# Determine arr type and config directory name
		case "$lock_basename" in
			sonarr)
				arr_type="sonarr"
				config_dir_name="Sonarr"
				instance_name="sonarr"
				;;
			sonarr_*)
				arr_type="sonarr"
				instance_name="${lock_basename/sonarr_/sonarr-}"
				config_dir_name="${instance_name}"
				;;
			radarr)
				arr_type="radarr"
				config_dir_name="Radarr"
				instance_name="radarr"
				;;
			radarr_*)
				arr_type="radarr"
				instance_name="${lock_basename/radarr_/radarr-}"
				config_dir_name="${instance_name}"
				;;
			lidarr)
				arr_type="lidarr"
				config_dir_name="Lidarr"
				instance_name="lidarr"
				;;
			lidarr_*)
				arr_type="lidarr"
				instance_name="${lock_basename/lidarr_/lidarr-}"
				config_dir_name="${instance_name}"
				;;
			readarr)
				arr_type="readarr"
				config_dir_name="Readarr"
				instance_name="readarr"
				;;
			readarr_*)
				arr_type="readarr"
				instance_name="${lock_basename/readarr_/readarr-}"
				config_dir_name="${instance_name}"
				;;
			*) continue ;;
		esac

		# Find config.xml
		for cfg in /home/*/.config/"${config_dir_name}"/config.xml; do
			[[ -f "$cfg" ]] || continue

			port=$(grep -oP '(?<=<Port>)[^<]+' "$cfg" 2>/dev/null) || continue
			apikey=$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" 2>/dev/null) || continue
			urlbase=$(grep -oP '(?<=<UrlBase>)[^<]+' "$cfg" 2>/dev/null) || true

			ARR_NAMES+=("$instance_name")
			ARR_TYPES+=("$arr_type")
			ARR_PORTS+=("$port")
			ARR_APIKEYS+=("$apikey")
			ARR_URLBASES+=("${urlbase:-}")

			_verbose "Found ${instance_name} on port ${port} (urlbase: ${urlbase:-none})"
			break
		done
	done

	if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
		echo_warn "No arr instances found"
	else
		echo_progress_done "Found ${#ARR_NAMES[@]} arr instance(s): ${ARR_NAMES[*]}"
	fi
}

# ==============================================================================
# Media Server Auto-Discovery
# ==============================================================================

# Parallel arrays populated by _discover_media_servers
MS_NAMES=()
MS_TYPES=()    # "emby" or "jellyfin" or "plex"
MS_URLS=()
MS_TOKENS=()

_discover_media_servers() {
	echo_progress_start "Discovering media servers"

	# --- Emby ---
	if [[ -f /install/.emby.lock ]]; then
		local emby_port="8096"
		local emby_token=""

		# Try to find existing API key from Emby
		if [[ -f /var/lib/emby/config/system.xml ]]; then
			# Check if there's an existing Autopulse API key we created before
			emby_token=$(swizdb get "${app_name}/emby_token" 2>/dev/null) || true
		fi

		# If no stored token, create one via Emby API
		if [[ -z "$emby_token" ]]; then
			_verbose "Creating Emby API key for Autopulse"

			# Need an existing admin token to create new API keys
			# Read one from Emby's authentication database
			local admin_token=""
			local emby_auth_db="/var/lib/emby/data/authentication.db"
			if [[ -f "$emby_auth_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
				admin_token=$(sqlite3 "$emby_auth_db" \
					"SELECT AccessToken FROM Tokens_2 WHERE IsActive=1 ORDER BY DateLastActivityInt DESC LIMIT 1;" 2>/dev/null) || true
			fi

			if [[ -n "$admin_token" ]]; then
				# Create a dedicated Autopulse API key
				curl -s -X POST \
					"http://127.0.0.1:${emby_port}/emby/Auth/Keys" \
					-H "X-Emby-Token: ${admin_token}" \
					-H "Content-Type: application/x-www-form-urlencoded" \
					-d "App=Autopulse" 2>/dev/null || true

				# Read back the keys to find ours
				local keys_json
				keys_json=$(curl -s -H "X-Emby-Token: ${admin_token}" \
					"http://127.0.0.1:${emby_port}/emby/Auth/Keys" 2>/dev/null) || true
				if [[ -n "$keys_json" ]]; then
					emby_token=$(echo "$keys_json" | jq -r \
						'.Items[]? | select(.AppName == "Autopulse") | .AccessToken' 2>/dev/null | head -1) || true
				fi
			fi

			if [[ -z "$emby_token" ]]; then
				echo_warn "Could not auto-create Emby API key."
				echo_info "Create one manually: Emby Dashboard > API Keys > New"
				echo_query "Enter Emby API key (or leave empty to skip):" ""
				read -r emby_token </dev/tty 2>/dev/null || true
			fi
		fi

		if [[ -n "$emby_token" ]]; then
			MS_NAMES+=("emby")
			MS_TYPES+=("emby")
			MS_URLS+=("http://127.0.0.1:${emby_port}")
			MS_TOKENS+=("$emby_token")
			swizdb set "${app_name}/emby_token" "$emby_token"
			_verbose "Found Emby on port ${emby_port}"
		fi
	fi

	# --- Jellyfin ---
	if [[ -f /install/.jellyfin.lock ]]; then
		local jf_port="8096"
		local jf_token=""

		# Check for stored token
		jf_token=$(swizdb get "${app_name}/jellyfin_token" 2>/dev/null) || true

		# Try to find port from Jellyfin config
		local jf_network_xml
		for jf_network_xml in /var/lib/jellyfin/config/network.xml /home/*/.config/jellyfin/network.xml; do
			if [[ -f "$jf_network_xml" ]]; then
				local jf_cfg_port
				jf_cfg_port=$(grep -oP '(?<=<HttpServerPortNumber>)[^<]+' "$jf_network_xml" 2>/dev/null) || true
				[[ -n "$jf_cfg_port" ]] && jf_port="$jf_cfg_port"
				break
			fi
		done

		# If no stored token, create one via Jellyfin API
		if [[ -z "$jf_token" ]]; then
			_verbose "Creating Jellyfin API key for Autopulse"
			# Jellyfin requires an existing admin API key to create new keys
			# Try to find one from existing config or prompt
			echo_query "Enter Jellyfin API key (Settings > API Keys > Add):" ""
			read -r jf_token </dev/tty 2>/dev/null || true
		fi

		if [[ -n "$jf_token" ]]; then
			MS_NAMES+=("jellyfin")
			MS_TYPES+=("jellyfin")
			MS_URLS+=("http://127.0.0.1:${jf_port}")
			MS_TOKENS+=("$jf_token")
			swizdb set "${app_name}/jellyfin_token" "$jf_token"
			_verbose "Found Jellyfin on port ${jf_port}"
		fi
	fi

	# --- Plex ---
	if [[ -f /install/.plex.lock ]]; then
		local plex_port="32400"
		local plex_token=""

		# Read token from Preferences.xml
		local plex_prefs
		for plex_prefs in "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml" \
			/home/*/.config/plexmediaserver/Preferences.xml; do
			if [[ -f "$plex_prefs" ]]; then
				plex_token=$(grep -oP 'PlexOnlineToken="[^"]*"' "$plex_prefs" 2>/dev/null \
					| head -1 | sed 's/PlexOnlineToken="//;s/"//') || true
				break
			fi
		done

		if [[ -z "$plex_token" ]]; then
			echo_query "Enter Plex token (from Preferences.xml or plex.tv/claim):" ""
			read -r plex_token </dev/tty 2>/dev/null || true
		fi

		if [[ -n "$plex_token" ]]; then
			MS_NAMES+=("plex")
			MS_TYPES+=("plex")
			MS_URLS+=("http://127.0.0.1:${plex_port}")
			MS_TOKENS+=("$plex_token")
			_verbose "Found Plex on port ${plex_port}"
		fi
	fi

	if [[ ${#MS_NAMES[@]} -eq 0 ]]; then
		echo_warn "No media servers found. Autopulse needs at least one target."
		echo_info "You can manually edit ${app_dir}/config.yaml after install."
	else
		echo_progress_done "Found ${#MS_NAMES[@]} media server(s): ${MS_NAMES[*]}"
	fi
}

# ==============================================================================
# Config Generation
# ==============================================================================
_generate_config() {
	echo_progress_start "Generating Autopulse configuration"

	mkdir -p "${app_dir}/data"
	chown -R "${user}:${user}" "$app_dir"

	# Persist ports
	swizdb set "${app_name}/port" "$app_port"
	swizdb set "${app_name}/ui_port" "$app_ui_port"
	swizdb set "${app_name}/owner" "$user"

	# Generate or reuse auth password (module-level for _generate_compose)
	if _auth_password="$(swizdb get "${app_name}/auth_password" 2>/dev/null)" && [[ -n "$_auth_password" ]]; then
		_verbose "Reusing existing auth password"
	elif [[ -n "${AUTOPULSE_AUTH_PASSWORD:-}" ]]; then
		_auth_password="$AUTOPULSE_AUTH_PASSWORD"
	else
		_auth_password=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c -16)
	fi
	swizdb set "${app_name}/auth_password" "$_auth_password"

	# Generate or reuse UI secret (module-level for _generate_compose)
	if _ui_secret="$(swizdb get "${app_name}/ui_secret" 2>/dev/null)" && [[ -n "$_ui_secret" ]]; then
		_verbose "Reusing existing UI secret"
	else
		_ui_secret=$(openssl rand -hex 32)
	fi
	swizdb set "${app_name}/ui_secret" "$_ui_secret"

	# --- Build config.yaml ---
	{
		cat <<-YAML
		app:
		  hostname: 0.0.0.0
		  port: ${app_port}
		  log_level: info

		auth:
		  username: ${user}
		  password: ${_auth_password}

		YAML

		# Triggers section
		if [[ ${#ARR_NAMES[@]} -gt 0 ]]; then
			echo "triggers:"
			local i
			for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
				echo "  ${ARR_NAMES[$i]}:"
				echo "    type: ${ARR_TYPES[$i]}"
			done
			echo ""
		fi

		# Targets section
		if [[ ${#MS_NAMES[@]} -gt 0 ]]; then
			echo "targets:"
			local i
			for ((i = 0; i < ${#MS_NAMES[@]}; i++)); do
				echo "  ${MS_NAMES[$i]}:"
				echo "    type: ${MS_TYPES[$i]}"
				echo "    url: ${MS_URLS[$i]}"
				echo "    token: ${MS_TOKENS[$i]}"
			done
			echo ""
		fi
	} >"${app_dir}/config.yaml"

	chmod 640 "${app_dir}/config.yaml"
	chown "root:${app_group}" "${app_dir}/config.yaml"

	echo_progress_done "Configuration generated"
}

# ==============================================================================
# Media Path Resolution
# ==============================================================================
# Resolve every host path autopulse needs to stat: the symlinks tree that the
# *arrs import to, plus every backing source mount (zurg, nzbdav, any future
# provider).  Provider-agnostic: discovers from three signals and collapses
# nested paths to their common parent.
#
# Sources (any present is honoured; results are merged):
#   1. AUTOPULSE_MEDIA_PATHS env (colon-separated, overrides discovery)
#   2. Sonarr/Radarr RootFolders (gives the symlinks tree generically)
#   3. swizdb */mount_point and */mount_path keys (provider-agnostic — any
#      Swizzin app following the convention: zurg, nzbdav, etc.)
#   4. Filesystem fallback (/mnt/symlinks, /mnt/zurg, /mnt/nzbdav, /mnt/media)
_resolve_media_paths() {
	MEDIA_PATHS=()
	local -a _discovered=()
	local p

	if [[ -n "${AUTOPULSE_MEDIA_PATHS:-}" ]]; then
		# Explicit override — honour as-is, skip discovery
		local IFS=:
		for p in $AUTOPULSE_MEDIA_PATHS; do
			_discovered+=("${p%/}")
		done
		unset IFS
	else
		# 1. *arr RootFolders. Add the root itself AND its parent (so two roots
		#    sharing a parent collapse to one mount in the nested-dedup pass).
		#    Reject parents that are too broad (/, /mnt, /media, /home).
		if command -v sqlite3 >/dev/null 2>&1; then
			local db root parent
			for db in /home/*/.config/Sonarr*/sonarr.db /home/*/.config/Radarr*/radarr.db; do
				[[ -f "$db" ]] || continue
				while IFS= read -r root; do
					[[ -n "$root" ]] || continue
					root="${root%/}"
					_discovered+=("$root")
					parent=$(dirname "$root")
					case "$parent" in /|/mnt|/media|/home) continue ;; esac
					_discovered+=("$parent")
				done < <(sqlite3 "$db" "SELECT Path FROM RootFolders;" 2>/dev/null)
			done
		fi

		# 2. Provider mounts from swizdb — any app using the */mount_point or
		#    */mount_path convention (zurg, nzbdav, decypharr, future providers).
		local key val
		for key in /var/lib/swizzin/db/*/mount_point /var/lib/swizzin/db/*/mount_path; do
			[[ -f "$key" ]] || continue
			val=$(cat "$key" 2>/dev/null)
			[[ -n "$val" ]] && _discovered+=("${val%/}")
		done

		# 3. Filesystem fallback when nothing else turned up
		if [[ ${#_discovered[@]} -eq 0 ]]; then
			for p in /mnt/symlinks /mnt/zurg /mnt/nzbdav /mnt/media; do
				[[ -d "$p" ]] && _discovered+=("$p")
			done
		fi
	fi

	# Dedupe + keep only existing directories
	local -A _seen=()
	local -a _existing=()
	for p in "${_discovered[@]:-}"; do
		[[ -n "$p" && -d "$p" && -z "${_seen[$p]:-}" ]] || continue
		_seen[$p]=1
		_existing+=("$p")
	done

	# Collapse: drop any path that's a strict subdirectory of another (so
	# /mnt/symlinks/movies + /mnt/symlinks/series both fall under /mnt/symlinks).
	local x y is_nested
	for y in "${_existing[@]:-}"; do
		is_nested=0
		for x in "${_existing[@]:-}"; do
			[[ "$x" != "$y" && "$y" == "$x"/* ]] && { is_nested=1; break; }
		done
		[[ $is_nested -eq 0 ]] && MEDIA_PATHS+=("$y")
	done

	if [[ ${#MEDIA_PATHS[@]} -gt 0 ]]; then
		echo_info "Mounting media paths into autopulse:"
		for p in "${MEDIA_PATHS[@]}"; do echo_info "  $p"; done
	else
		echo_warn "No media paths discovered - autopulse will mark every event as not_found"
		echo_warn "Set AUTOPULSE_MEDIA_PATHS=/path1:/path2 to override"
	fi
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
_generate_compose() {
	echo_progress_start "Generating Docker Compose configuration"

	local uid gid
	uid=$(id -u "$user")
	gid=$(id -g "$user")

	# Use module-level _auth_password and _ui_secret set by _generate_config

	# Build media bind-mount lines (long-form syntax: rslave propagation lets
	# the container see the underlying FUSE mounts at /mnt/zurg).
	local media_volume_lines=""
	if [[ ${#MEDIA_PATHS[@]} -gt 0 ]]; then
		local path
		for path in "${MEDIA_PATHS[@]}"; do
			media_volume_lines+=$'\n'"      - type: bind"
			media_volume_lines+=$'\n'"        source: ${path}"
			media_volume_lines+=$'\n'"        target: ${path}"
			media_volume_lines+=$'\n'"        read_only: true"
			media_volume_lines+=$'\n'"        bind:"
			media_volume_lines+=$'\n'"          propagation: rslave"
		done
	fi

	cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  autopulse:
    image: ${app_image_api}
    container_name: autopulse
    restart: unless-stopped
    network_mode: host
    user: "${uid}:${gid}"
    environment:
      AUTOPULSE__APP__DATABASE_URL: sqlite://data/autopulse.db
      AUTOPULSE__APP__PORT: "${app_port}"
    volumes:
      - ${app_dir}/config.yaml:/app/config.yaml:ro
      - ${app_dir}/data:/app/data${media_volume_lines}
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  autopulse-ui:
    image: ${app_image_ui}
    container_name: autopulse-ui
    restart: unless-stopped
    network_mode: host
    environment:
      BASE_PATH: /autopulse
      ORIGIN: http://localhost:${app_ui_port}
      PORT: "${app_ui_port}"
      FORCE_AUTH: "true"
      FORCE_SERVER_URL: http://localhost:${app_port}
      FORCE_USERNAME: ${user}
      FORCE_PASSWORD: ${_auth_password}
      SECRET: ${_ui_secret}
    depends_on:
      - autopulse
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
COMPOSE

	chmod 600 "${app_dir}/docker-compose.yml"
	chown root:root "${app_dir}/docker-compose.yml"

	echo_progress_done "Docker Compose configuration generated"
}

# ==============================================================================
# Systemd Service
# ==============================================================================
_systemd_autopulse() {
	echo_progress_start "Installing systemd service"

	cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Media Server Library Notifier)
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

[Install]
WantedBy=multi-user.target
EOF

	_systemd_unit_written="$app_servicefile"
	systemctl -q daemon-reload
	systemctl enable -q "$app_servicefile"
	echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Reverse Proxy
# ==============================================================================
_nginx_autopulse() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"

		cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_ui_port}/${app_baseurl}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /${app_baseurl}/triggers/ {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/triggers/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

		_nginx_config_written="/etc/nginx/apps/${app_name}.conf"
		_reload_nginx
		echo_progress_done "Nginx configured"
	else
		echo_info "${app_pretty} API running on port ${app_port}, UI on port ${app_ui_port}"
	fi
}

# ==============================================================================
# Panel Registration
# ==============================================================================
_panel_autopulse() {
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
# Arr Webhook Auto-Configuration
# ==============================================================================
_configure_arr_webhooks() {
	if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
		return 0
	fi

	echo_progress_start "Configuring arr webhooks"

	local i
	for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
		local name="${ARR_NAMES[$i]}"
		local port="${ARR_PORTS[$i]}"
		local apikey="${ARR_APIKEYS[$i]}"
		local urlbase="${ARR_URLBASES[$i]}"
		local base_url="http://127.0.0.1:${port}"
		[[ -n "$urlbase" ]] && base_url="${base_url}/${urlbase#/}"

		local webhook_url="http://127.0.0.1:${app_port}/triggers/${name}"
		local autopulse_user="$user"
		local autopulse_pass
		autopulse_pass=$(swizdb get "${app_name}/auth_password" 2>/dev/null) || true

		_verbose "Configuring webhook for ${name} -> ${webhook_url}"

		# Check for existing Autopulse notification
		local existing
		existing=$(curl -s --config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
			"${base_url}/api/v3/notification" 2>/dev/null) || true

		local already_exists=false
		if [[ -n "$existing" ]] && echo "$existing" | jq -e '.[] | select(.name == "Autopulse")' >/dev/null 2>&1; then
			already_exists=true
		fi

		if [[ "$already_exists" == "true" ]]; then
			_verbose "Autopulse webhook already configured in ${name}, skipping"
			continue
		fi

		# Determine event field names based on arr type
		local payload
		payload=$(cat <<-JSONEOF
		{
		  "name": "Autopulse",
		  "implementation": "Webhook",
		  "implementationName": "Webhook",
		  "configContract": "WebhookSettings",
		  "enable": true,
		  "onGrab": false,
		  "onDownload": true,
		  "onUpgrade": true,
		  "onRename": true,
		  "onSeriesDelete": true,
		  "onEpisodeFileDelete": true,
		  "onMovieDelete": true,
		  "onMovieFileDelete": true,
		  "onAlbumDelete": true,
		  "onTrackFileDelete": true,
		  "onBookDelete": true,
		  "onBookFileDelete": true,
		  "onHealthIssue": false,
		  "supportsOnGrab": true,
		  "supportsOnDownload": true,
		  "supportsOnUpgrade": true,
		  "supportsOnRename": true,
		  "supportsOnSeriesDelete": true,
		  "supportsOnEpisodeFileDelete": true,
		  "supportsOnMovieDelete": true,
		  "supportsOnMovieFileDelete": true,
		  "supportsOnAlbumDelete": true,
		  "supportsOnTrackFileDelete": true,
		  "supportsOnBookDelete": true,
		  "supportsOnBookFileDelete": true,
		  "fields": [
		    {"name": "url", "value": "${webhook_url}"},
		    {"name": "method", "value": 1},
		    {"name": "username", "value": "${autopulse_user}"},
		    {"name": "password", "value": "${autopulse_pass}"}
		  ],
		  "tags": []
		}
		JSONEOF
		)

		local http_code
		http_code=$(curl -s -o /dev/null -w '%{http_code}' \
			--config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
			-X POST "${base_url}/api/v3/notification?forceSave=true" \
			-H "Content-Type: application/json" \
			-d "$payload" 2>/dev/null) || true

		if [[ "$http_code" == "201" ]]; then
			_verbose "Webhook added to ${name}"
		else
			echo_warn "Failed to add webhook to ${name} (HTTP ${http_code})"
		fi
	done

	echo_progress_done "Arr webhooks configured"
}

# ==============================================================================
# Optionally disable existing media server Connect entries
# ==============================================================================
_disable_arr_media_connects() {
	if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
		return 0
	fi

	# Skip prompt if non-interactive (no tty)
	if [[ ! -t 0 ]]; then
		_verbose "Non-interactive mode, skipping media connect disable prompt"
		return 0
	fi

	if ! ask "Disable existing Emby/Jellyfin/Plex Connect entries in arr instances?\n(These trigger slow full library scans that Autopulse replaces)" Y; then
		return 0
	fi

	local i
	for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
		local name="${ARR_NAMES[$i]}"
		local port="${ARR_PORTS[$i]}"
		local apikey="${ARR_APIKEYS[$i]}"
		local urlbase="${ARR_URLBASES[$i]}"
		local base_url="http://127.0.0.1:${port}"
		[[ -n "$urlbase" ]] && base_url="${base_url}/${urlbase#/}"

		local notifications
		notifications=$(curl -s --config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
			"${base_url}/api/v3/notification" 2>/dev/null) || continue

		# Find Emby/Jellyfin/Plex connect entries and disable them
		local ids_to_disable
		ids_to_disable=$(echo "$notifications" | jq -r \
			'.[] | select(.implementation == "Emby" or .implementation == "Jellyfin" or .implementation == "PlexServer" or .implementation == "Plex") | select(.enable == true) | .id' 2>/dev/null) || continue

		for nid in $ids_to_disable; do
			local existing_notification
			existing_notification=$(echo "$notifications" | jq ".[] | select(.id == $nid)" 2>/dev/null) || continue

			# Set enable=false
			local updated
			updated=$(echo "$existing_notification" | jq '.enable = false' 2>/dev/null) || continue

			curl -s -o /dev/null \
				--config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
				-X PUT "${base_url}/api/v3/notification/${nid}" \
				-H "Content-Type: application/json" \
				-d "$updated" 2>/dev/null || true

			local impl_name
			impl_name=$(echo "$existing_notification" | jq -r '.implementation' 2>/dev/null) || impl_name="unknown"
			_verbose "Disabled ${impl_name} connect in ${name} (id=${nid})"
		done
	done

	echo_info "Existing media server Connect entries disabled"
}

# ==============================================================================
# Fresh Install Orchestration
# ==============================================================================
_install_fresh() {
	if [[ -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_pretty} is already installed. Use --update to update."
		exit 1
	fi

	_cleanup_needed=true

	echo_info "Installing ${app_pretty}..."

	_install_docker
	_ensure_jq
	_discover_arrs
	_discover_media_servers
	_resolve_media_paths
	_generate_config
	_generate_compose

	echo_progress_start "Pulling ${app_pretty} Docker images"
	docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
		echo_error "Failed to pull Docker images"
		exit 1
	}
	echo_progress_done "Docker images pulled"

	echo_progress_start "Starting ${app_pretty} containers"
	docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
		echo_error "Failed to start containers"
		exit 1
	}
	echo_progress_done "${app_pretty} containers started"

	_systemd_autopulse
	_nginx_autopulse
	_panel_autopulse

	# Wait for Autopulse API to be ready before configuring webhooks
	echo_progress_start "Waiting for ${app_pretty} API"
	local attempts=0
	while [[ $attempts -lt 30 ]]; do
		if curl -s -o /dev/null "http://127.0.0.1:${app_port}/" 2>/dev/null; then
			break
		fi
		sleep 1
		((attempts++)) || true
	done
	echo_progress_done "${app_pretty} API ready"

	_configure_arr_webhooks
	_disable_arr_media_connects

	# Create lock file
	touch "/install/.${app_lockname}.lock"
	_lock_file_created="/install/.${app_lockname}.lock"

	_cleanup_needed=false

	echo_success "${app_pretty} installed successfully!"
	echo_info "Dashboard: https://$(hostname -f)/autopulse/"
	echo_info "Auth: ${user} / $(swizdb get "${app_name}/auth_password" 2>/dev/null)"
	if [[ ${#ARR_NAMES[@]} -gt 0 ]]; then
		echo_info "Webhooks configured for: ${ARR_NAMES[*]}"
	fi
}

# ==============================================================================
# Update
# ==============================================================================
_update_autopulse() {
	if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_pretty} is not installed"
		exit 1
	fi

	echo_info "Updating ${app_pretty}..."

	_ensure_jq

	# Re-discover and regenerate config (picks up new arr instances / media servers)
	_discover_arrs
	_discover_media_servers
	_resolve_media_paths
	_generate_config
	_generate_compose

	echo_progress_start "Pulling latest ${app_pretty} images"
	_verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
	docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
		echo_error "Failed to pull latest images"
		exit 1
	}
	echo_progress_done "Latest images pulled"

	echo_progress_start "Recreating ${app_pretty} containers"
	_verbose "Running: docker compose up -d"
	docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
		echo_error "Failed to recreate containers"
		exit 1
	}
	echo_progress_done "Containers recreated"

	_verbose "Pruning unused images"
	docker image prune -f >>"$log" 2>&1 || true

	# Re-configure webhooks for any new arr instances
	_configure_arr_webhooks

	echo_success "${app_pretty} has been updated"
	exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_autopulse() {
	local force="${1:-}"

	if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_pretty} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_pretty}..."

	# Ask about purging configuration
	local purgeconfig="false"
	if [[ "$force" == "--force" ]]; then
		purgeconfig="true"
	elif ask "Would you like to purge the configuration?" N; then
		purgeconfig="true"
	fi

	# Stop and remove containers
	echo_progress_start "Stopping ${app_pretty} containers"
	if [[ -f "${app_dir}/docker-compose.yml" ]]; then
		docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
	fi
	echo_progress_done "Containers stopped"

	# Remove Docker images
	echo_progress_start "Removing Docker images"
	docker rmi "$app_image_api" >>"$log" 2>&1 || true
	docker rmi "$app_image_ui" >>"$log" 2>&1 || true
	echo_progress_done "Docker images removed"

	# Remove systemd service
	echo_progress_start "Removing systemd service"
	systemctl stop "$app_servicefile" 2>/dev/null || true
	systemctl disable "$app_servicefile" 2>/dev/null || true
	rm -f "/etc/systemd/system/${app_servicefile}"
	systemctl daemon-reload
	echo_progress_done "Service removed"

	# Remove nginx config
	if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
		echo_progress_start "Removing nginx configuration"
		_remove_nginx_conf "$app_name"
		_reload_nginx 2>/dev/null || true
		echo_progress_done "Nginx configuration removed"
	fi

	# Remove from panel
	_load_panel_helper
	if command -v panel_unregister_app >/dev/null 2>&1; then
		echo_progress_start "Removing from panel"
		panel_unregister_app "$app_name"
		echo_progress_done "Removed from panel"
	fi

	# Remove webhooks from arr instances
	_ensure_jq 2>/dev/null || true
	_discover_arrs 2>/dev/null || true
	if [[ ${#ARR_NAMES[@]} -gt 0 ]]; then
		echo_progress_start "Removing Autopulse webhooks from arr instances"
		local i
		for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
			local name="${ARR_NAMES[$i]}"
			local port="${ARR_PORTS[$i]}"
			local apikey="${ARR_APIKEYS[$i]}"
			local urlbase="${ARR_URLBASES[$i]}"
			local base_url="http://127.0.0.1:${port}"
			[[ -n "$urlbase" ]] && base_url="${base_url}/${urlbase#/}"

			local notifications
			notifications=$(curl -s --config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
				"${base_url}/api/v3/notification" 2>/dev/null) || continue

			local nid
			nid=$(echo "$notifications" | jq -r '.[] | select(.name == "Autopulse") | .id' 2>/dev/null) || continue

			if [[ -n "$nid" ]]; then
				curl -s -o /dev/null \
					--config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
					-X DELETE "${base_url}/api/v3/notification/${nid}" 2>/dev/null || true
				_verbose "Removed webhook from ${name}"
			fi
		done
		echo_progress_done "Webhooks removed"
	fi

	# Purge or keep config
	if [[ "$purgeconfig" = "true" ]]; then
		echo_progress_start "Purging configuration and data"
		rm -f "${app_dir}/config.yaml" "${app_dir}/docker-compose.yml"
		rm -f "${app_dir}/data/autopulse.db" 2>/dev/null || true
		rmdir "${app_dir}/data" 2>/dev/null || true
		rmdir "${app_dir}" 2>/dev/null || true
		echo_progress_done "Files purged"
		swizdb clear "${app_name}/owner" 2>/dev/null || true
		swizdb clear "${app_name}/port" 2>/dev/null || true
		swizdb clear "${app_name}/ui_port" 2>/dev/null || true
		swizdb clear "${app_name}/auth_password" 2>/dev/null || true
		swizdb clear "${app_name}/ui_secret" 2>/dev/null || true
		swizdb clear "${app_name}/emby_token" 2>/dev/null || true
		swizdb clear "${app_name}/jellyfin_token" 2>/dev/null || true
	else
		echo_info "Configuration kept at: ${app_dir}"
	fi

	# Remove lock file
	rm -f "/install/.${app_lockname}.lock"

	echo_success "${app_pretty} has been removed"
	exit 0
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

# Parse global flags
for arg in "$@"; do
	case "$arg" in
		--verbose) verbose=true ;;
	esac
done

case "${1:-}" in
	"--update")
		_update_autopulse
		;;
	"--remove")
		_remove_autopulse "${2:-}"
		;;
	"--register-panel")
		if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
			echo_error "${app_pretty} is not installed"
			exit 1
		fi
		_panel_autopulse
		systemctl restart panel 2>/dev/null || true
		echo_success "Panel registration updated for ${app_pretty}"
		;;
	"")
		_install_fresh
		;;
	*)
		echo "Usage: $0 [--update [--verbose]|--remove [--force]|--register-panel]"
		exit 1
		;;
esac
