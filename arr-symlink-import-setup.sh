#!/bin/bash
# arr-symlink-import-setup.sh - Arr Symlink Import installer/manager
# STiXzoOR 2026
# Usage: arr-symlink-import-setup.sh [--install|--remove|--status|--diagnose]
#
# Deploys the arr-symlink-import.sh script for use with Sonarr/Radarr's
# "Import Using Script" feature. Prevents "Permission denied" errors caused
# by FUSE mount transient unavailability when importing/upgrading media
# through symlinks to a zurg rclone mount.

set -euo pipefail

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# ==============================================================================
# Signal Traps
# ==============================================================================
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Constants
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT_SCRIPT="$SCRIPT_DIR/arr-symlink-import.sh"
CONFIG_EXAMPLE="$SCRIPT_DIR/configs/arr-symlink-import.conf.example"

INSTALL_DIR="/opt/swizzin-extras"
IMPORT_DEST="$INSTALL_DIR/arr-symlink-import.sh"
CONFIG_DEST="$INSTALL_DIR/arr-symlink-import.conf"

LOG_FILE="/var/log/arr-symlink-import.log"

# ==============================================================================
# Helper Functions
# ==============================================================================

echo_info()    { echo -e "\033[0;34m[INFO]\033[0m $1"; }
echo_warn()    { echo -e "\033[0;33m[WARN]\033[0m $1"; }
echo_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
echo_success() { echo -e "\033[0;32m[OK]\033[0m $1"; }

ask() {
	local prompt="$1"
	local default="${2:-N}"
	local answer

	if [[ "$default" == "Y" ]]; then
		read -rp "$prompt [Y/n]: " answer </dev/tty
		[[ -z "$answer" || "$answer" =~ ^[Yy] ]]
	else
		read -rp "$prompt [y/N]: " answer </dev/tty
		[[ "$answer" =~ ^[Yy] ]]
	fi
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

_check_root() {
	if [[ $EUID -ne 0 ]]; then
		echo_error "This script must be run as root"
		exit 1
	fi
}

_check_arr_installed() {
	local found=false
	if [[ -f "/install/.sonarr.lock" ]]; then found=true; fi
	if [[ -f "/install/.radarr.lock" ]]; then found=true; fi
	# Check multi-instance lock files
	for lock in /install/.sonarr-*.lock /install/.radarr-*.lock; do
		if [[ -f "$lock" ]]; then found=true; break; fi
	done

	if [[ "$found" != "true" ]]; then
		echo_error "No Sonarr or Radarr installation found"
		echo_info "Install Sonarr or Radarr first, then re-run this script"
		exit 1
	fi
}

_check_zurg_installed() {
	if [[ ! -f "/install/.zurg.lock" ]]; then
		echo_warn "Zurg is not installed - symlink import requires a zurg mount"
		if ! ask "Continue anyway?" N; then
			exit 0
		fi
	fi
}

_check_source_files() {
	if [[ ! -f "$IMPORT_SCRIPT" ]]; then
		echo_error "Import script not found: $IMPORT_SCRIPT"
		exit 1
	fi

	if [[ ! -f "$CONFIG_EXAMPLE" ]]; then
		echo_error "Config example not found: $CONFIG_EXAMPLE"
		exit 1
	fi
}

# ==============================================================================
# Arr Instance Detection
# ==============================================================================

_detect_arr_instances() {
	# Returns lines of: app_name|service_name|config_dir|url_path
	local instances=()

	# Base Sonarr
	if [[ -f "/install/.sonarr.lock" ]]; then
		local sonarr_user
		sonarr_user=$(grep -l 'Sonarr' /etc/systemd/system/sonarr.service 2>/dev/null | head -1)
		if [[ -n "$sonarr_user" ]]; then
			# Find config dir from service file
			local sonarr_config
			for cfg in /home/*/.config/Sonarr; do
				if [[ -d "$cfg" ]]; then
					sonarr_config="$cfg"
					break
				fi
			done
			instances+=("Sonarr|sonarr|${sonarr_config:-unknown}|/sonarr")
		fi
	fi

	# Base Radarr
	if [[ -f "/install/.radarr.lock" ]]; then
		local radarr_config
		for cfg in /home/*/.config/Radarr; do
			if [[ -d "$cfg" ]]; then
				radarr_config="$cfg"
				break
			fi
		done
		instances+=("Radarr|radarr|${radarr_config:-unknown}|/radarr")
	fi

	# Multi-instance Sonarr
	for lock in /install/.sonarr-*.lock; do
		if [[ -f "$lock" ]]; then
			local name
			name=$(basename "$lock" | sed 's/^\.sonarr-//;s/\.lock$//')
			local inst_config
			for cfg in /home/*/.config/sonarr-"$name"; do
				if [[ -d "$cfg" ]]; then
					inst_config="$cfg"
					break
				fi
			done
			instances+=("Sonarr ($name)|sonarr-$name|${inst_config:-unknown}|/sonarr-$name")
		fi
	done

	# Multi-instance Radarr
	for lock in /install/.radarr-*.lock; do
		if [[ -f "$lock" ]]; then
			local name
			name=$(basename "$lock" | sed 's/^\.radarr-//;s/\.lock$//')
			local inst_config
			for cfg in /home/*/.config/radarr-"$name"; do
				if [[ -d "$cfg" ]]; then
					inst_config="$cfg"
					break
				fi
			done
			instances+=("Radarr ($name)|radarr-$name|${inst_config:-unknown}|/radarr-$name")
		fi
	done

	printf '%s\n' "${instances[@]}"
}

# ==============================================================================
# Installation
# ==============================================================================

_install_script() {
	echo_info "Installing import script..."

	mkdir -p "$INSTALL_DIR"
	cp "$IMPORT_SCRIPT" "$IMPORT_DEST"
	chmod +x "$IMPORT_DEST"

	echo_success "Import script installed: $IMPORT_DEST"
}

_install_config() {
	if [[ -f "$CONFIG_DEST" ]]; then
		echo_info "Config already exists, skipping: $CONFIG_DEST"
		return
	fi

	echo_info "Creating config from template..."

	# Detect zurg mount for config
	local zurg_base="/mnt/zurg"
	if command -v swizdb &>/dev/null; then
		local db_mount
		db_mount=$(swizdb get "zurg/mount_point" 2>/dev/null) || true
		if [[ -n "$db_mount" ]]; then
			zurg_base="$db_mount"
		fi
	fi

	cp "$CONFIG_EXAMPLE" "$CONFIG_DEST"

	# Uncomment and set the detected zurg base if it differs from default
	if [[ "$zurg_base" != "/mnt/zurg" ]]; then
		sed -i "s|^# ARR_ZURG_BASE=.*|ARR_ZURG_BASE=\"$zurg_base\"|" "$CONFIG_DEST"
	fi

	chmod 644 "$CONFIG_DEST"
	echo_success "Config created: $CONFIG_DEST"
}

_create_log_dir() {
	# Pre-create the log file with correct ownership so the service user can write to it
	# (Sonarr/Radarr run the script as the service user, not root)
	local log_dir
	log_dir=$(dirname "$LOG_FILE")
	if [[ ! -d "$log_dir" ]]; then
		mkdir -p "$log_dir"
		chmod 755 "$log_dir"
	fi
	touch "$LOG_FILE"
	chmod 666 "$LOG_FILE"
	echo_success "Log file created with write permissions: $LOG_FILE"
}

_print_setup_instructions() {
	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "  Setup Instructions"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""

	local instances
	instances=$(_detect_arr_instances)

	if [[ -z "$instances" ]]; then
		echo_warn "No Sonarr/Radarr instances detected"
		return
	fi

	echo "For each instance below, apply these settings:"
	echo ""

	while IFS='|' read -r display_name service_name config_dir url_path; do
		echo -e "  \033[1m$display_name\033[0m (service: $service_name)"
		echo "    1. Open Settings > Media Management > Importing"
		echo "    2. Enable \"Use Script Import\""
		echo "    3. Set Import Script Path to: $IMPORT_DEST"
		echo "    4. Open Settings > Media Management > File Management"
		echo "    5. Clear the \"Recycling Bin\" path (leave empty)"
		echo ""
	done <<< "$instances"

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""
	echo_info "Script: $IMPORT_DEST"
	echo_info "Config: $CONFIG_DEST"
	echo_info "Logs:   $LOG_FILE"
	echo ""
}

_install() {
	echo_info "Installing Arr Symlink Import..."
	echo ""

	_check_arr_installed
	_check_zurg_installed
	_check_source_files

	_install_script
	_install_config
	_create_log_dir

	echo ""
	echo_success "Arr Symlink Import installed!"

	_print_setup_instructions
}

# ==============================================================================
# Removal
# ==============================================================================

_remove() {
	echo_info "Removing Arr Symlink Import..."

	# Remove script
	if [[ -f "$IMPORT_DEST" ]]; then
		rm -f "$IMPORT_DEST"
		echo_success "Removed import script"
	fi

	# Remove config
	if [[ -f "$CONFIG_DEST" ]]; then
		if ask "Remove config file?" N; then
			rm -f "$CONFIG_DEST"
			echo_success "Removed config"
		else
			echo_info "Config kept: $CONFIG_DEST"
		fi
	fi

	# Remove log
	if [[ -f "$LOG_FILE" ]] || [[ -f "${LOG_FILE}.1" ]]; then
		if ask "Remove log files?" N; then
			rm -f "$LOG_FILE" "${LOG_FILE}.1"
			echo_success "Removed log files"
		fi
	fi

	echo ""
	echo_success "Arr Symlink Import removed"
	echo ""
	echo_warn "Remember to disable 'Use Script Import' in each Sonarr/Radarr instance"
	echo ""
}

# ==============================================================================
# Status
# ==============================================================================

_status() {
	echo ""
	echo "Arr Symlink Import Status"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""

	# Script installed?
	if [[ -f "$IMPORT_DEST" ]]; then
		echo -e "Script:    $IMPORT_DEST (\033[0;32minstalled\033[0m)"
	else
		echo -e "Script:    $IMPORT_DEST (\033[0;31mnot installed\033[0m)"
	fi

	# Config?
	if [[ -f "$CONFIG_DEST" ]]; then
		echo -e "Config:    $CONFIG_DEST (\033[0;32mpresent\033[0m)"
	else
		echo -e "Config:    $CONFIG_DEST (\033[0;33musing defaults\033[0m)"
	fi

	# Zurg base detection
	local zurg_base="/mnt/zurg"
	if command -v swizdb &>/dev/null; then
		local db_mount
		db_mount=$(swizdb get "zurg/mount_point" 2>/dev/null) || true
		if [[ -n "$db_mount" ]]; then
			zurg_base="$db_mount"
		fi
	fi
	echo "Zurg base: $zurg_base"

	# Mount status
	if mountpoint -q "$zurg_base" 2>/dev/null; then
		echo -e "Mount:     $zurg_base (\033[0;32mmounted\033[0m)"
	else
		echo -e "Mount:     $zurg_base (\033[0;31mnot mounted\033[0m)"
	fi

	# Log info
	if [[ -f "$LOG_FILE" ]]; then
		local log_size
		log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
		local last_entry
		last_entry=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -d']' -f1 | tr -d '[')
		echo "Log:       $LOG_FILE ($log_size)"
		if [[ -n "$last_entry" ]]; then
			echo "Last log:  $last_entry"
		fi
	else
		echo "Log:       $LOG_FILE (no log yet)"
	fi

	# Detected instances
	echo ""
	echo "Detected Arr Instances:"

	local instances
	instances=$(_detect_arr_instances 2>/dev/null) || true

	if [[ -z "$instances" ]]; then
		echo "  (none found)"
	else
		while IFS='|' read -r display_name service_name config_dir url_path; do
			local svc_status
			if systemctl is-active --quiet "$service_name" 2>/dev/null; then
				svc_status="\033[0;32mrunning\033[0m"
			else
				svc_status="\033[0;31mstopped\033[0m"
			fi
			echo -e "  $display_name ($service_name) - $svc_status"
		done <<< "$instances"
	fi

	echo ""
}

# ==============================================================================
# Diagnostics
# ==============================================================================

_diagnose() {
	echo ""
	echo "Arr Symlink Import Diagnostics"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""

	local issues=0

	# 1. Script deployment
	echo "1. Script Deployment"
	if [[ -f "$IMPORT_DEST" ]]; then
		if [[ -x "$IMPORT_DEST" ]]; then
			echo_success "   Import script is deployed and executable"
		else
			echo_error "   Import script exists but is not executable"
			echo_info "   Fix: chmod +x $IMPORT_DEST"
			((issues++)) || true
		fi
	else
		echo_error "   Import script not deployed"
		echo_info "   Fix: $0 --install"
		((issues++)) || true
	fi

	# 2. Zurg mount health
	echo ""
	echo "2. Zurg Mount Health"
	local zurg_base="/mnt/zurg"
	if command -v swizdb &>/dev/null; then
		local db_mount
		db_mount=$(swizdb get "zurg/mount_point" 2>/dev/null) || true
		if [[ -n "$db_mount" ]]; then
			zurg_base="$db_mount"
		fi
	fi

	if [[ ! -d "$zurg_base" ]]; then
		echo_error "   Mount path does not exist: $zurg_base"
		((issues++)) || true
	elif ! mountpoint -q "$zurg_base" 2>/dev/null; then
		echo_error "   Not a mount point: $zurg_base"
		echo_info "   Fix: systemctl restart zurg (or rclone-zurg for free version)"
		((issues++)) || true
	elif ! timeout 5 ls "$zurg_base" &>/dev/null; then
		echo_error "   Mount is unresponsive: $zurg_base"
		echo_info "   Fix: systemctl restart zurg && systemctl restart rclone-zurg"
		((issues++)) || true
	else
		echo_success "   Mount is healthy: $zurg_base"

		# Check __all__ directory
		if timeout 5 ls "$zurg_base/__all__/" &>/dev/null; then
			local file_count
			file_count=$(timeout 5 ls "$zurg_base/__all__/" 2>/dev/null | wc -l)
			echo_success "   __all__ directory accessible ($file_count entries)"
		else
			echo_warn "   __all__ directory not accessible"
		fi
	fi

	# 3. FUSE configuration
	echo ""
	echo "3. FUSE Configuration"
	if [[ -f /etc/fuse.conf ]]; then
		if grep -q "^user_allow_other" /etc/fuse.conf; then
			echo_success "   user_allow_other is enabled in /etc/fuse.conf"
		else
			echo_error "   user_allow_other is NOT enabled in /etc/fuse.conf"
			echo_info "   Fix: echo 'user_allow_other' >> /etc/fuse.conf"
			((issues++)) || true
		fi
	else
		echo_warn "   /etc/fuse.conf not found"
	fi

	# 4. Broken symlinks
	echo ""
	echo "4. Broken Symlinks"

	local broken_downloads=0
	local broken_library=0

	# Check download symlinks
	if [[ -d "/mnt/symlinks/downloads" ]]; then
		broken_downloads=$(find /mnt/symlinks/downloads -xtype l 2>/dev/null | wc -l)
		if [[ "$broken_downloads" -gt 0 ]]; then
			echo_warn "   Found $broken_downloads broken symlinks in /mnt/symlinks/downloads/"
			find /mnt/symlinks/downloads -xtype l 2>/dev/null | head -5 | while read -r link; do
				echo "         $link -> $(readlink "$link" 2>/dev/null || echo '(unreadable)')"
			done
			if [[ "$broken_downloads" -gt 5 ]]; then
				echo "         ... and $((broken_downloads - 5)) more"
			fi
		else
			echo_success "   No broken symlinks in /mnt/symlinks/downloads/"
		fi
	else
		echo_info "   /mnt/symlinks/downloads/ not found (may be normal)"
	fi

	# Check library symlinks (common locations)
	for lib_dir in /mnt/symlinks/series /mnt/symlinks/movies /mnt/symlinks/tv /mnt/symlinks/films; do
		if [[ -d "$lib_dir" ]]; then
			local broken
			broken=$(find "$lib_dir" -xtype l 2>/dev/null | wc -l)
			if [[ "$broken" -gt 0 ]]; then
				echo_warn "   Found $broken broken symlinks in $lib_dir/"
				broken_library=$((broken_library + broken))
			else
				echo_success "   No broken symlinks in $lib_dir/"
			fi
		fi
	done

	if [[ "$broken_downloads" -gt 0 ]] || [[ "$broken_library" -gt 0 ]]; then
		((issues++)) || true
	fi

	# 5. Arr instance configuration
	echo ""
	echo "5. Arr Instance Settings"

	local instances
	instances=$(_detect_arr_instances 2>/dev/null) || true

	if [[ -z "$instances" ]]; then
		echo_warn "   No Sonarr/Radarr instances detected"
	else
		while IFS='|' read -r display_name service_name config_dir url_path; do
			echo ""
			echo "   $display_name:"

			# Check service user
			local svc_user
			svc_user=$(grep -oP '(?<=User=)\S+' "/etc/systemd/system/${service_name}.service" 2>/dev/null) || true
			if [[ -n "$svc_user" ]]; then
				echo_info "   Service user: $svc_user"
			fi

			# Check settings in SQLite database
			# Media management settings (RecycleBin, UseScriptImport, ScriptImportPath)
			# are stored in the Config table of the app's SQLite database, not config.xml.
			if [[ -d "$config_dir" ]]; then
				# Find the database file (sonarr.db / radarr.db)
				local db_file=""
				for candidate in "$config_dir"/*.db; do
					if [[ -f "$candidate" ]]; then
						db_file="$candidate"
						break
					fi
				done

				if [[ -n "$db_file" ]] && command -v sqlite3 &>/dev/null; then
					# Check recycle bin
					local recyclebin
					recyclebin=$(sqlite3 "$db_file" "SELECT Value FROM Config WHERE Key = 'recyclebin';" 2>/dev/null) || true
					if [[ -n "$recyclebin" ]]; then
						echo_warn "   Recycle Bin is set to: $recyclebin"
						echo_info "   Recommendation: Clear Recycle Bin path to avoid permission errors"
						((issues++)) || true
					else
						echo_success "   Recycle Bin is disabled (good)"
					fi

					# Check if script import is enabled
					local use_script
					use_script=$(sqlite3 "$db_file" "SELECT Value FROM Config WHERE Key = 'usescriptimport';" 2>/dev/null) || true
					if [[ "$use_script" == "True" ]]; then
						echo_success "   Script Import is enabled"
						local script_path
						script_path=$(sqlite3 "$db_file" "SELECT Value FROM Config WHERE Key = 'scriptimportpath';" 2>/dev/null) || true
						if [[ "$script_path" == "$IMPORT_DEST" ]]; then
							echo_success "   Script path is correct: $script_path"
						elif [[ -n "$script_path" ]]; then
							echo_warn "   Script path: $script_path (expected: $IMPORT_DEST)"
						fi
					else
						echo_warn "   Script Import is NOT enabled"
						echo_info "   Enable: Settings > Media Management > Importing > Use Script Import"
						((issues++)) || true
					fi
				elif [[ -z "$db_file" ]]; then
					echo_warn "   Database not found in: $config_dir"
				else
					echo_warn "   sqlite3 not available, cannot check settings"
					echo_info "   Install with: apt install sqlite3"
				fi
			else
				echo_warn "   Config dir not found: $config_dir"
			fi
		done <<< "$instances"
	fi

	# 6. Zurg services
	echo ""
	echo "6. Zurg Services"
	if systemctl is-active --quiet zurg 2>/dev/null; then
		echo_success "   zurg.service is running"
	else
		echo_error "   zurg.service is not running"
		((issues++)) || true
	fi

	if systemctl list-unit-files rclone-zurg.service &>/dev/null 2>&1; then
		if systemctl is-active --quiet rclone-zurg 2>/dev/null; then
			echo_success "   rclone-zurg.service is running (free version)"
		else
			echo_warn "   rclone-zurg.service exists but is not running"
		fi
	else
		echo_info "   rclone-zurg.service not found (paid version uses internal rclone)"
	fi

	# Summary
	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	if [[ "$issues" -eq 0 ]]; then
		echo_success "All checks passed!"
	else
		echo_warn "$issues issue(s) found - see details above"
	fi
	echo ""
}

# ==============================================================================
# Usage
# ==============================================================================

_usage() {
	echo "Arr Symlink Import Manager"
	echo ""
	echo "Usage: $0 [OPTION]"
	echo ""
	echo "Deploys and manages the symlink import script for Sonarr/Radarr."
	echo "Prevents 'Permission denied' errors when importing/upgrading media"
	echo "through symlinks pointing to a zurg rclone FUSE mount."
	echo ""
	echo "Options:"
	echo "  --install    Deploy import script and create config"
	echo "  --remove     Remove import script and config"
	echo "  --status     Show current deployment status"
	echo "  --diagnose   Run full diagnostics (mount, symlinks, arr config)"
	echo "  -h, --help   Show this help message"
	echo ""
	echo "Without options, runs in interactive mode."
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

_interactive() {
	echo ""
	echo "Arr Symlink Import Setup"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""

	if [[ -f "$IMPORT_DEST" ]]; then
		_status

		echo "What would you like to do?"
		echo "  1) Show status (already shown above)"
		echo "  2) Run diagnostics"
		echo "  3) Reinstall script"
		echo "  4) Remove"
		echo "  5) Exit"
		echo ""
		read -rp "Choice [1-5]: " choice </dev/tty

		case "$choice" in
			1) _status ;;
			2) _diagnose ;;
			3) _install_script; echo_success "Script reinstalled" ;;
			4) _remove ;;
			5) exit 0 ;;
			*) echo_error "Invalid choice"; exit 1 ;;
		esac
	else
		echo_info "Arr Symlink Import is not installed"
		echo ""

		if ask "Install Arr Symlink Import?" Y; then
			_install
		fi
	fi
}

# ==============================================================================
# Main
# ==============================================================================

_check_root

case "${1:-}" in
	--install)
		_install
		;;
	--remove)
		_remove
		;;
	--status)
		_status
		;;
	--diagnose)
		_diagnose
		;;
	-h|--help)
		_usage
		;;
	"")
		_interactive
		;;
	*)
		echo_error "Unknown option: $1"
		_usage
		exit 1
		;;
esac
