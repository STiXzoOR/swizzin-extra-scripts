#!/bin/bash
# Apply patched Bazarr subtitle providers before startup
# Called via ExecStartPre in bazarr systemd services
OVERLAY_DIR="/opt/swizzin-scripts/overlays/bazarr/providers"
TARGET_DIR="/opt/bazarr/custom_libs/subliminal_patch/providers"

if [ -d "$OVERLAY_DIR" ] && [ -d "$TARGET_DIR" ]; then
    cp "$OVERLAY_DIR"/*.py "$TARGET_DIR"/
fi
