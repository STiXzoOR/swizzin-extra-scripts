#!/bin/bash
# ==============================================================================
# NGINX COMPRESSION (gzip + brotli)
# ==============================================================================
# Fixes the single largest bandwidth/latency defect on a Swizzin box: nginx's
# DEFAULT gzip_types is "text/html" ONLY, so `gzip on` alone leaves every
# JSON/JS/CSS response uncompressed.
#
# Measured on a live box 2026-09-09:
#   /api/v2/homepage  = 229 MB over 251 requests (calendar alone 2,651,305 B)
#   /docs/api.json    = 175,036 B -> gzip 6,865 (25.5x) -> brotli 4,555 (38.4x)
#
# Brotli is built FROM SOURCE because no open-source nginx ships it:
#   - nginx.org OSS repo modules: acme, geoip, image-filter, njs, otel, perl, xslt
#   - the official brotli package is NGINX Plus only
#   - Ubuntu's libnginx-mod-http-brotli-filter Depends: <nginx-abi-1.24.0-1>
#     and cannot install against an nginx.org build
#
# Because a source-built module is orphaned by an nginx upgrade (and nginx then
# REFUSES TO START), this installs an APT guard that disables the module and
# its directives together if the config ever stops testing clean.
#
# Usage: sudo bash nginx-compression.sh [--install|--update|--remove|--status]
# ==============================================================================

set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/bootstrap/lib/common.sh" ]]; then
    # shellcheck source=bootstrap/lib/common.sh
    . "${SCRIPT_DIR}/bootstrap/lib/common.sh"
else
    echo_info() { echo "[INFO] $1"; }
    echo_success() { echo "[OK] $1"; }
    echo_warn() { echo "[WARN] $1"; }
    echo_error() { echo "[ERROR] $1"; }
    echo_header() {
        echo ""
        echo "=== $1 ==="
        echo ""
    }
fi

# shellcheck source=lib/nginx-utils.sh
. "${SCRIPT_DIR}/lib/nginx-utils.sh" 2>/dev/null || true

GZIP_CONF="/etc/nginx/conf.d/compression.conf"
BROTLI_CONF="/etc/nginx/conf.d/compression-brotli.conf"
BROTLI_MOD="/etc/nginx/modules-enabled/50-mod-http-brotli.conf"
MOD_DIR="/usr/lib/nginx/modules"
GUARD_BIN="/usr/local/bin/nginx-module-guard"
GUARD_APT="/etc/apt/apt.conf.d/99-nginx-brotli-guard"
BACKUP_DIR="/opt/swizzin-extras/nginx-compression-backups"

# Deliberately excludes already-compressed formats (jpg/png/webp/mp4/mkv/woff2)
# and text/html (always compressed; listing it triggers a duplicate-type warning).
COMPRESS_TYPES="application/atom+xml application/geo+json application/javascript
    application/json application/ld+json application/manifest+json
    application/rdf+xml application/rss+xml application/vnd.api+json
    application/wasm application/x-javascript application/x-web-app-manifest+json
    application/xhtml+xml application/xml font/eot font/otf font/ttf image/bmp
    image/svg+xml image/vnd.microsoft.icon image/x-icon text/cache-manifest
    text/calendar text/css text/javascript text/markdown text/plain text/vcard
    text/vtt text/x-component text/x-cross-domain-policy text/xml"

_nginx_version() { nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }

_types_block() {
    local d="$1"
    printf '%s\n' "$COMPRESS_TYPES" | tr -s ' \n' ' ' | sed "s/^/${d} /; s/ \$/;/"
}

write_gzip_conf() {
    echo_info "Writing ${GZIP_CONF}"
    {
        cat <<'HDR'
# ==============================================================================
# Compression (gzip) - managed by swizzin-scripts/nginx-compression.sh
# ==============================================================================
# nginx's DEFAULT gzip_types is text/html ONLY. Without this file, `gzip on`
# leaves every JSON/JS/CSS response uncompressed.
# NOTE: text/html must NOT be listed (nginx warns "duplicate MIME type").
# NOTE: netdata sets `gzip off` in its own location on purpose (SSE/live
#       charts); this http-level config does not override that.
gzip                on;
gzip_vary           on;
gzip_proxied        any;
gzip_comp_level     5;
gzip_min_length     1024;
gzip_disable        "msie6";
gzip_buffers        16 8k;
gzip_http_version   1.1;
HDR
        _types_block "gzip_types"
    } >"$GZIP_CONF"

    # nginx.conf ships its own `gzip on;`; neutralise it so this file is authoritative.
    if grep -qE '^[[:space:]]*gzip on;' /etc/nginx/nginx.conf; then
        sed -i 's|^[[:space:]]*gzip on;|\t# gzip is configured in conf.d/compression.conf (swizzin-scripts)|' /etc/nginx/nginx.conf
        echo_success "nginx.conf gzip directive delegated to ${GZIP_CONF}"
    fi
}

build_brotli() {
    local ver src tmp confargs
    ver="$(_nginx_version)"
    echo_info "Building ngx_brotli against nginx ${ver}"

    if ! nginx -V 2>&1 | grep -q -- '--with-compat'; then
        echo_error "nginx lacks --with-compat; cannot load third-party dynamic modules"
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -qq build-essential cmake git wget libpcre2-dev \
        zlib1g-dev libssl-dev libbrotli-dev >/dev/null 2>&1; then
        echo_error "build dependency installation failed"
        return 1
    fi

    tmp="$(mktemp -d)"
    src="${tmp}/nginx-${ver}"

    if ! (cd "$tmp" &&
        wget -q "https://nginx.org/download/nginx-${ver}.tar.gz" &&
        tar xzf "nginx-${ver}.tar.gz" &&
        git clone -q --recursive https://github.com/google/ngx_brotli.git); then
        echo_error "source fetch failed"
        rm -rf -- "$tmp"
        return 1
    fi

    # Must reuse the EXACT configure args or the module fails its binary-compat
    # check at load time ("module is not binary compatible").
    confargs="$(nginx -V 2>&1 | grep '^configure arguments:' | sed 's/^configure arguments: //')"

    if ! (cd "$src" &&
        eval ./configure "$confargs" --add-dynamic-module=../ngx_brotli >/dev/null 2>&1 &&
        make modules -j"$(nproc)" >/dev/null 2>&1); then
        echo_error "module build failed"
        rm -rf -- "$tmp"
        return 1
    fi

    install -m 0644 "${src}/objs/ngx_http_brotli_filter_module.so" "$MOD_DIR/"
    install -m 0644 "${src}/objs/ngx_http_brotli_static_module.so" "$MOD_DIR/"
    echo "$ver" >"${MOD_DIR}/.brotli-built-for"
    rm -rf -- "$tmp"

    cat >"$BROTLI_MOD" <<EOF
# ngx_brotli built from source against nginx ${ver} (--with-compat).
# If nginx is upgraded past ${ver} this module can fail its binary-compat check
# and nginx would refuse to start; ${GUARD_BIN} disables this file AND
# ${BROTLI_CONF} together in that case.
# Rebuild after an upgrade with: nginx-compression.sh --update
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;
EOF

    {
        cat <<EOF
# ==============================================================================
# Compression (brotli) - managed by swizzin-scripts/nginx-compression.sh
# ==============================================================================
# SEPARATE FILE ON PURPOSE: \`brotli on;\` without the module loaded is itself
# an "unknown directive" emerg, so the guard must disable module + directives
# together or nginx still will not start.
# Clients that do not advertise \`br\` fall back to gzip in compression.conf.
brotli              on;
brotli_comp_level   5;
brotli_min_length   1024;
# No .br files are pre-generated, so static would cost a stat() per request.
brotli_static       off;
EOF
        _types_block "brotli_types"
    } >"$BROTLI_CONF"

    echo_success "ngx_brotli installed for nginx ${ver}"
}

install_guard() {
    cat >"$GUARD_BIN" <<'EOF'
#!/bin/bash
# Fail-safe for source-built nginx dynamic modules (brotli).
# An nginx upgrade can orphan a module built for the previous version; nginx
# then fails its binary-compat check and REFUSES TO START. Prefer a running
# nginx without brotli over a dead nginx with it.
set -uo pipefail
CONF=/etc/nginx/modules-enabled/50-mod-http-brotli.conf
DIRECTIVES=/etc/nginx/conf.d/compression-brotli.conf
BUILT_FOR_FILE=/usr/lib/nginx/modules/.brotli-built-for
[[ -f $CONF ]] || exit 0
command -v nginx >/dev/null || exit 0
NOW=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
BUILT=$(cat "$BUILT_FOR_FILE" 2>/dev/null || echo unknown)
if nginx -t >/dev/null 2>&1; then
    [[ "$NOW" == "$BUILT" ]] || logger -t nginx-module-guard "nginx $NOW != brotli built-for $BUILT, config still OK"
    exit 0
fi
mv "$CONF" "${CONF}.disabled-by-guard"
[[ -f $DIRECTIVES ]] && mv "$DIRECTIVES" "${DIRECTIVES}.disabled-by-guard"
if nginx -t >/dev/null 2>&1; then
    logger -t nginx-module-guard "DISABLED brotli (built for $BUILT, nginx now $NOW). Rebuild: nginx-compression.sh --update"
    echo "nginx-module-guard: brotli disabled (nginx $NOW vs module $BUILT). Rebuild: nginx-compression.sh --update" >&2
else
    mv "${CONF}.disabled-by-guard" "$CONF"
    [[ -f ${DIRECTIVES}.disabled-by-guard ]] && mv "${DIRECTIVES}.disabled-by-guard" "$DIRECTIVES"
    logger -t nginx-module-guard "nginx -t fails for an unrelated reason; config left untouched"
fi
EOF
    chmod +x "$GUARD_BIN"
    cat >"$GUARD_APT" <<EOF
// Re-validate nginx config after any package operation and disable an orphaned
// source-built module so nginx can still start. See ${GUARD_BIN}
DPkg::Post-Invoke { "if [ -x ${GUARD_BIN} ]; then ${GUARD_BIN} || true; fi"; };
EOF
    echo_success "Upgrade guard installed"
}

do_install() {
    echo_header "nginx compression (gzip + brotli)"
    [[ -d /etc/nginx ]] || {
        echo_error "nginx not installed"
        exit 1
    }
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/nginx "${BACKUP_DIR}/nginx-$(date +%Y%m%d-%H%M%S)"
    write_gzip_conf
    if build_brotli; then
        install_guard
    else
        echo_warn "brotli unavailable - continuing with gzip only"
        rm -f "$BROTLI_CONF" "$BROTLI_MOD"
    fi
    nginx -t && { _reload_nginx 2>/dev/null || systemctl reload nginx; }
    echo_success "Compression enabled"
}

do_update() {
    echo_header "Rebuilding brotli for current nginx"
    rm -f "${BROTLI_MOD}.disabled-by-guard" "${BROTLI_CONF}.disabled-by-guard"
    build_brotli && install_guard
    nginx -t && { _reload_nginx 2>/dev/null || systemctl reload nginx; }
}

do_remove() {
    echo_header "Removing compression config"
    rm -f "$GZIP_CONF" "$BROTLI_CONF" "$BROTLI_MOD" "$GUARD_APT" "$GUARD_BIN"
    rm -f "${BROTLI_CONF}.disabled-by-guard" "${BROTLI_MOD}.disabled-by-guard"
    rm -f "${MOD_DIR}/ngx_http_brotli_filter_module.so"
    rm -f "${MOD_DIR}/ngx_http_brotli_static_module.so"
    sed -i 's|^\t# gzip is configured in conf.d/compression.conf (swizzin-scripts)|\tgzip on;|' /etc/nginx/nginx.conf
    nginx -t && { _reload_nginx 2>/dev/null || systemctl reload nginx; }
    echo_success "Removed"
}

do_status() {
    echo_header "Compression status"
    echo "  nginx version   : $(_nginx_version)"
    echo "  gzip conf       : $([[ -f $GZIP_CONF ]] && echo present || echo MISSING)"
    echo "  brotli module   : $([[ -f $BROTLI_MOD ]] && echo enabled || echo 'absent/disabled')"
    echo "  brotli built for: $(cat "${MOD_DIR}/.brotli-built-for" 2>/dev/null || echo n/a)"
    echo "  upgrade guard   : $([[ -x $GUARD_BIN ]] && echo installed || echo MISSING)"
    nginx -t 2>&1 | tail -1
}

case "${1:-}" in
    --install | -i | "") do_install ;;
    --update | -u) do_update ;;
    --remove | -r) do_remove ;;
    --status | -s) do_status ;;
    --help | -h) echo "Usage: $0 [--install|--update|--remove|--status]" ;;
    *)
        echo "Usage: $0 [--install|--update|--remove|--status]"
        exit 1
        ;;
esac
